import XCTest
@testable import NostromoKit

// Contract: whatever text lands in a fence, the tokenizer never crashes, never returns a malformed
// range, never splits a Unicode scalar, runs in linear time (measured by the step counter, not the
// wall clock), honours its size caps, and does not use a regex engine on code text.

/// Deterministic PRNG so every run sees the same inputs (no `SystemRandomNumberGenerator`).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Repeats `unit` after `prefix` up to exactly `n` units. Once the newline budget is spent the
/// unit's newlines become spaces so the input never trips the 1,000-line cap (which would make
/// the test vacuous).
private func repeated(_ unit: String, to n: Int, prefix: String = "") -> String {
    var out = prefix
    var length = prefix.utf16.count
    var newlines = prefix.filter { $0 == "\n" }.count
    let unitNewlines = unit.filter { $0 == "\n" }.count
    let spaced = unit.replacingOccurrences(of: "\n", with: " ")
    while length < n {
        if newlines + unitNewlines <= 990 {
            out += unit
            newlines += unitNewlines
        } else {
            out += spaced
        }
        length += unit.utf16.count
    }
    return String(out.prefix(n))
}


final class SyntaxHighlighterRobustnessTests: XCTestCase {

    // MARK: Shared data

    /// Every language id the table documents.
    private static let allLanguageIDs: [String] = [
        "sql", "mysql", "postgres", "postgresql", "psql", "sqlite", "plpgsql",
        "php",
        "bash", "sh", "zsh", "shell",
        "json", "jsonc", "json5",
        "yaml", "yml",
        "swift",
        "rust", "rs",
        "python", "py", "python3",
        "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx",
        "diff", "patch",
        "text", "plain", "txt", "plaintext",
    ]

    private static var languagesUnderTest: [String?] {
        allLanguageIDs.map { Optional($0) } + [nil]
    }

    /// One snippet per language family that always yields at least one token.
    private static let highlightedSamples: [(language: String, sample: String)] = [
        ("swift", "let x = 1"), ("sql", "select 1"), ("python", "None"), ("bash", "if"),
        ("json", "true"), ("yaml", "a: 1"), ("php", "<?php"), ("rust", "fn"),
        ("js", "const"), ("diff", "+x"),
    ]

    private static let nastyPieces: [String] = {
        let singles = ["'", "\"", "`", "#", "/", "*", "-", "<", ">", "$", "{", "}", "(", ")", "[", "]",
                       "@", "\\", "\n", "\t", " ", "r", "b", "f", "a", "1", "_", ":", ";", "|", "&",
                       "!", "?", "=", ".", "~", "%", "+", ","]
        // Multi-character openers and closers raise the hit rate of the interesting branches.
        let fragments = ["<<<", "<<", "<<-", "<?php", "<?=", "?>", "EOF", "EOT", "\"\"\"", "'''", "/*", "*/",
                         "//", "--", "${", "$(", "\\(", "\\#(", "r#\"", "br#\"", "\"#", "#\"", "#[", "#![",
                         "---", "...", "&a", "*a", "!!", "true", "null", "None", "0x", "1e", "'a", "\n\n",
                         "\r\n", "diff --git", "@@", "+++ ", "--- ", "<<EOF\n", "<<'EOF'\n"]
        let unicode = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                       "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
                       "\u{200B}", "\u{200E}", "\u{200F}", "\u{FEFF}",
                       "\u{0301}", "\u{0308}", "e\u{0301}", "\u{E9}", "\u{FFFD}", "\u{0}",
                       "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F600}", "\u{1F1FA}\u{1F1F8}",
                       "\u{1D11E}", "\u{10FFFF}", "\u{2028}", "\u{2029}", "\u{85}"]
        return singles + fragments + unicode
    }()

    // MARK: Generators

    private func randomBytesString(_ rng: inout SplitMix64) -> String {
        let length = Int.random(in: 0...2_000, using: &rng)
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for _ in 0..<length { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func nastyString(_ rng: inout SplitMix64) -> String {
        let pieces = Int.random(in: 0...700, using: &rng)
        var out = ""
        for _ in 0..<pieces {
            out += Self.nastyPieces.randomElement(using: &rng)!
            if out.utf16.count > 2_000 { break }
        }
        return out
    }

    // MARK: Validation

    /// Returns a description of the first violated invariant, or nil when the tokens are well formed.
    private func problem(with tokens: [SyntaxToken], in code: String) -> String? {
        let count = code.utf16.count
        var previousEnd = 0
        for token in tokens {
            let r = token.utf16Range
            if r.isEmpty { return "empty range \(r)" }
            if r.lowerBound < 0 || r.upperBound > count { return "range \(r) outside 0..<\(count)" }
            if r.lowerBound < previousEnd { return "range \(r) overlaps or is out of order (previous end \(previousEnd))" }
            previousEnd = r.upperBound
            for offset in [r.lowerBound, r.upperBound] {
                let index = String.Index(utf16Offset: offset, in: code)
                if index.samePosition(in: code.unicodeScalars) == nil {
                    return "boundary \(offset) of \(r) splits a Unicode scalar"
                }
            }
        }
        return nil
    }

    private func stepCount(_ code: String, _ language: String) -> Int {
        var steps = 0
        _ = SyntaxHighlighter.tokens(in: code, language: language, steps: &steps)
        return steps
    }

    // MARK: Fuzz

    func testFuzzedInputsAlwaysYieldSortedNonOverlappingInBoundsScalarAlignedTokensForEveryLanguage() {
        var failures = 0
        for (languageIndex, language) in Self.languagesUnderTest.enumerated() {
            var rng = SplitMix64(seed: 0x5EED_0000 &+ UInt64(languageIndex))
            for iteration in 0..<300 {
                // Alternate raw (often invalid) UTF-8 bytes with the nasty delimiter/Unicode alphabet.
                let code = iteration % 2 == 0 ? randomBytesString(&rng) : nastyString(&rng)
                let tokens = SyntaxHighlighter.tokens(in: code, language: language)
                if let why = problem(with: tokens, in: code) {
                    XCTFail("language \(String(describing: language)), iteration \(iteration): \(why); input \(code.debugDescription.prefix(300))")
                    failures += 1
                    if failures >= 10 { return }
                }
            }
        }
    }

    func testEmptyInputYieldsNoTokensForEveryLanguage() {
        for language in Self.languagesUnderTest {
            XCTAssertEqual(SyntaxHighlighter.tokens(in: "", language: language), [])
        }
    }

    func testInvalidUTF8DecodedAsReplacementCharactersNeverBreaksTheRanges() {
        let bytes: [UInt8] = Array("let s = \"".utf8) + [0xFF, 0xFE, 0xC0, 0x80, 0xED, 0xA0, 0x80] + Array("\" // x\n".utf8)
        let code = String(decoding: bytes, as: UTF8.self)
        for language in Self.languagesUnderTest {
            let tokens = SyntaxHighlighter.tokens(in: code, language: language)
            XCTAssertNil(problem(with: tokens, in: code), "language \(String(describing: language))")
        }
    }

    // MARK: Bidi and invisible characters

    /// The tokenizer returns ranges only, so it cannot alter the text. What must hold is that a
    /// bidi/invisible character inside a string stays inside the one string token.
    func testBidiAndInvisibleCharactersInsideAStringStayInsideThatOneToken() {
        let hostile = "a\u{202E}b\u{2066}c\u{200B}d\u{200E}e\u{200F}f\u{FEFF}g\u{0301}\u{1F468}\u{200D}\u{1F469}"
        let cases: [(language: String, prefix: String, quote: String)] = [
            ("json", "[", "\""), ("js", "const s = ", "\""), ("python", "s = ", "\""),
            ("rust", "let s = ", "\""), ("swift", "let s = ", "\""), ("bash", "echo ", "\""),
            ("php", "$s = ", "\""), ("sql", "select ", "'"), ("yaml", "k: ", "\""),
        ]
        for (language, prefix, quote) in cases {
            let literal = quote + hostile + quote
            let code = prefix + literal + (language == "json" ? "]" : "")
            let units = Array(code.utf16)
            let tokens = SyntaxHighlighter.tokens(in: code, language: language)
            XCTAssertNil(problem(with: tokens, in: code), language)
            let strings = tokens.filter { $0.kind == .string }
            XCTAssertEqual(strings.count, 1, "\(language): expected one string token")
            if problem(with: tokens, in: code) == nil, let s = strings.first {
                XCTAssertEqual(String(decoding: units[s.utf16Range], as: UTF16.self), literal, language)
            }
        }
    }

    // MARK: Linear time

    private struct Adversary {
        let name: String
        let languages: [String]
        /// Builds an input of exactly `units` UTF-16 units (ASCII), under both caps.
        let make: (Int) -> String
    }

    private static let adversaries: [Adversary] = [
        Adversary(name: "unterminated block comments", languages: ["js", "rust", "swift", "sql", "php", "json"]) { repeated("/*", to: $0) },
        Adversary(name: "lone single quotes", languages: ["sql", "js", "python", "bash", "rust", "yaml", "php", "swift"]) { repeated("'", to: $0) },
        Adversary(name: "lone double quotes", languages: ["sql", "js", "python", "bash", "rust", "yaml", "php", "swift", "json"]) { repeated("\"", to: $0) },
        Adversary(name: "quote then backslash", languages: ["json", "js", "swift", "python", "rust", "bash", "php", "yaml"]) { repeated("\"\\", to: $0) },
        Adversary(name: "backticks", languages: ["js", "sql", "bash"]) { repeated("`", to: $0) },
        Adversary(name: "bash command substitutions", languages: ["bash"]) { repeated("$(", to: $0) },
        Adversary(name: "bash command substitutions inside double quotes", languages: ["bash"]) { repeated("$(", to: $0, prefix: "\"") },
        Adversary(name: "bash heredoc openers", languages: ["bash"]) { repeated("<<EOF\n", to: $0) },
        Adversary(name: "php heredoc openers", languages: ["php"]) { repeated("<<<EOT\n", to: $0) },
        Adversary(name: "swift interpolation openers in one string", languages: ["swift"]) { repeated("\\(", to: $0, prefix: "\"") },
        Adversary(name: "swift raw string openers", languages: ["swift"]) { repeated("#\"", to: $0) },
        Adversary(name: "swift multiline string openers", languages: ["swift"]) { repeated("\"\"\"a", to: $0) },
        Adversary(name: "rust raw string openers", languages: ["rust"]) { repeated("r#\"", to: $0) },
        Adversary(name: "rust lifetimes", languages: ["rust"]) { repeated("'a", to: $0) },
        Adversary(name: "python f-string braces", languages: ["python"]) { repeated("{", to: $0, prefix: "f\"") },
        Adversary(name: "python triple-quoted f-string braces", languages: ["python"]) { repeated("{", to: $0, prefix: "f'''") },
        Adversary(name: "python triple-quote openers", languages: ["python"]) { repeated("\"\"\"a", to: $0) },
        Adversary(name: "js template-literal interpolations", languages: ["js"]) { repeated("${", to: $0, prefix: "`") },
        Adversary(name: "js backtick pairs with braces", languages: ["js"]) { repeated("`${", to: $0) },
        Adversary(name: "yaml block-scalar indicators", languages: ["yaml"]) { repeated("a: |\n", to: $0) },
    ]

    func testAdversarialInputsOfTwentyThousandUnitsStayWithinAnEightStepsPerUnitBudget() {
        let n = SyntaxHighlighter.maxUTF16
        for adversary in Self.adversaries {
            let code = adversary.make(n)
            XCTAssertEqual(code.utf16.count, n, adversary.name)
            XCTAssertLessThan(code.filter { $0 == "\n" }.count, SyntaxHighlighter.maxLines, "\(adversary.name): input must stay under the line cap")
            for language in adversary.languages {
                let steps = stepCount(code, language)
                print("steps[\(adversary.name) / \(language)] n=\(n): \(steps)")
                XCTAssertLessThanOrEqual(steps, 8 * n, "\(adversary.name) in \(language): \(steps) steps for \(n) units")
                let tokens = SyntaxHighlighter.tokens(in: code, language: language)
                XCTAssertNil(problem(with: tokens, in: code), "\(adversary.name) in \(language)")
            }
        }
    }

    func testDoublingAnAdversarialInputAtMostDoublesTheStepsPlusTenPercent() {
        let n = SyntaxHighlighter.maxUTF16 / 2
        for adversary in Self.adversaries {
            let small = adversary.make(n)
            let large = adversary.make(2 * n)
            XCTAssertEqual(small.utf16.count, n, adversary.name)
            XCTAssertEqual(large.utf16.count, 2 * n, adversary.name)
            for language in adversary.languages {
                let stepsSmall = stepCount(small, language)
                let stepsLarge = stepCount(large, language)
                print("steps[\(adversary.name) / \(language)] n=\(n): \(stepsSmall), 2n=\(2 * n): \(stepsLarge)")
                XCTAssertLessThanOrEqual(Double(stepsLarge), 2.2 * Double(stepsSmall),
                                         "\(adversary.name) in \(language): \(stepsSmall) -> \(stepsLarge) is super-linear")
            }
        }
    }

    // MARK: Caps

    func testCapConstantsMatchTheDocumentedLimits() {
        XCTAssertEqual(SyntaxHighlighter.maxUTF16, 20_000)
        XCTAssertEqual(SyntaxHighlighter.maxLines, 1_000)
    }

    func testTwentyThousandUnitsAreHighlightedAndTwentyThousandAndOneAreNot() {
        for (language, sample) in Self.highlightedSamples {
            let at = sample + String(repeating: " ", count: 20_000 - sample.utf16.count)
            let over = at + " "
            XCTAssertEqual(at.utf16.count, 20_000)
            XCTAssertEqual(over.utf16.count, 20_001)
            XCTAssertFalse(SyntaxHighlighter.tokens(in: at, language: language).isEmpty, "\(language) at the cap")
            XCTAssertEqual(SyntaxHighlighter.tokens(in: over, language: language), [], "\(language) over the cap")
        }
    }

    func testTheUnitCapCountsUTF16UnitsNotCharacters() {
        let head = "let x = 1\n"
        let atCap = head + String(repeating: "\u{1F600}", count: (20_000 - head.utf16.count) / 2)
        XCTAssertEqual(atCap.utf16.count, 20_000)
        XCTAssertFalse(SyntaxHighlighter.tokens(in: atCap, language: "swift").isEmpty)
        let over = atCap + "\u{1F600}"
        XCTAssertEqual(over.utf16.count, 20_002)
        XCTAssertLessThan(over.unicodeScalars.count, 20_000)
        XCTAssertEqual(SyntaxHighlighter.tokens(in: over, language: "swift"), [])
    }

    func testNineHundredNinetyNineNewlinesAreHighlightedAndAThousandAreNot() {
        for (language, sample) in Self.highlightedSamples {
            let ok = sample + String(repeating: "\n", count: 999)
            let over = sample + String(repeating: "\n", count: 1_000)
            XCTAssertFalse(SyntaxHighlighter.tokens(in: ok, language: language).isEmpty, "\(language) with 999 newlines")
            XCTAssertEqual(SyntaxHighlighter.tokens(in: over, language: language), [], "\(language) with 1,000 newlines")
        }
    }

    func testTheLineCapAppliesToRealMultiLineCode() {
        let ok = String(repeating: "let x = 1\n", count: 999)
        let over = String(repeating: "let x = 1\n", count: 1_000)
        XCTAssertFalse(SyntaxHighlighter.tokens(in: ok, language: "swift").isEmpty)
        XCTAssertEqual(SyntaxHighlighter.tokens(in: over, language: "swift"), [])
    }

    // MARK: No regex engine on code text

    func testTheTokenizerSourcesDoNotUseARegexEngine() throws {
        // .../Shared/NostromoKit/Tests/NostromoKitTests/<this file>  ->  .../Shared/NostromoKit
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = ["SyntaxHighlighter.swift", "SyntaxLanguages.swift"].map {
            packageRoot.appendingPathComponent("Sources/NostromoKit/Syntax/\($0)")
        }
        let missing = sources.filter { !FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipUnless(missing.isEmpty, "tokenizer sources not present at \(missing.map(\.path))")
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for banned in ["NSRegularExpression", "Regex", ".regularExpression", "#/"] {
                XCTAssertFalse(text.contains(banned), "\(url.lastPathComponent) must not contain \(banned)")
            }
        }
    }
}
