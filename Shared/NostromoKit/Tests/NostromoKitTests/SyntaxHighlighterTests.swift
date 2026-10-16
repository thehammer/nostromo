import XCTest
@testable import NostromoKit

// Contract: `SyntaxHighlighter.tokens(in:language:)` returns colour tokens (UTF-16 ranges) for the
// common languages that show up in fenced code blocks, and nothing for unknown/plain languages.
//
// Tokens are rendered as `(kind, substring)` pairs so each assertion reads as a requirement.
// Where the spec leaves a choice (whether a string token includes its prefix such as `rb` or `#`,
// whether a YAML key token includes its colon, whether a heredoc token includes its opener line,
// PHP `::class`) the tests accept either answer or do not test it.

private struct Tok: Equatable, CustomStringConvertible {
    let kind: SyntaxTokenKind
    let text: String
    init(_ kind: SyntaxTokenKind, _ text: String) {
        self.kind = kind
        self.text = text
    }
    var description: String { "\(kind)(\(text.debugDescription))" }
}

final class SyntaxHighlighterTests: XCTestCase {

    // MARK: Helpers

    private func toks(_ code: String, _ language: String?) -> [Tok] {
        let units = Array(code.utf16)
        return SyntaxHighlighter.tokens(in: code, language: language).map { token in
            let r = token.utf16Range
            guard r.lowerBound >= 0, r.upperBound <= units.count, r.lowerBound <= r.upperBound else {
                return Tok(token.kind, "<out of bounds \(r)>")
            }
            return Tok(token.kind, String(decoding: units[r], as: UTF16.self))
        }
    }

    private func texts(_ tokens: [Tok], _ kind: SyntaxTokenKind) -> [String] {
        tokens.filter { $0.kind == kind }.map(\.text)
    }

    /// YAML keys may or may not include the trailing colon; compare without it.
    private func keyNames(_ tokens: [Tok]) -> [String] {
        texts(tokens, .key).map { text in
            var t = text
            while let last = t.last, last == ":" || last == " " { t.removeLast() }
            return t
        }
    }

    /// The whole of `code` is one string token. The token may include or exclude a literal prefix
    /// (`rb`, `f`, `r#`, `#`), so it must end at the end of the code and start no later than the
    /// first quote character.
    private func assertOneString(
        _ code: String, _ language: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let units = Array(code.utf16)
        let tokens = SyntaxHighlighter.tokens(in: code, language: language)
        guard tokens.count == 1, tokens[0].kind == .string else {
            XCTFail("expected exactly one string token in \(code.debugDescription) (\(language)), got \(toks(code, language))", file: file, line: line)
            return
        }
        let firstQuote = units.firstIndex { $0 == 0x22 || $0 == 0x27 || $0 == 0x60 } ?? 0
        XCTAssertEqual(tokens[0].utf16Range.upperBound, units.count,
                       "string must run to the end of \(code.debugDescription)", file: file, line: line)
        XCTAssertLessThanOrEqual(tokens[0].utf16Range.lowerBound, firstQuote,
                                 "string must not start after its opening quote in \(code.debugDescription)", file: file, line: line)
    }

    /// `needle` (first occurrence) lies entirely inside a single token of `kind`.
    private func isCovered(
        _ needle: String, in code: String, _ language: String, by kind: SyntaxTokenKind
    ) -> Bool {
        guard let found = code.range(of: needle) else { return false }
        let lo = code.utf16.distance(from: code.utf16.startIndex, to: found.lowerBound.samePosition(in: code.utf16)!)
        let hi = lo + needle.utf16.count
        return SyntaxHighlighter.tokens(in: code, language: language).contains {
            $0.kind == kind && $0.utf16Range.lowerBound <= lo && $0.utf16Range.upperBound >= hi
        }
    }

    // MARK: Fixture

    func testEveryLanguageFenceInTheHighlightedFixtureProducesTokensAndPlainFencesProduceNone() {
        let blocks = MarkdownFences.segments(of: MarkdownFenceFixtures.highlightedMessage).compactMap { segment -> MarkdownFences.CodeBlock? in
            if case .code(let block) = segment { return block }
            return nil
        }
        XCTAssertGreaterThanOrEqual(blocks.count, 12)
        for block in blocks {
            let tokens = SyntaxHighlighter.tokens(in: block.code, language: block.language)
            if block.language == nil || block.language == "text" {
                XCTAssertEqual(tokens, [], "plain fence \(block.info.debugDescription) must have no tokens")
            } else {
                XCTAssertFalse(tokens.isEmpty, "fence \(block.info.debugDescription) should be highlighted")
            }
        }
    }

    // MARK: SQL

    func testSQLLineCommentIsExactlyTheDashDashToEndOfLine() {
        let r = toks("SELECT a -- note\nFROM t", "sql")
        XCTAssertEqual(texts(r, .comment), ["-- note"])
        XCTAssertEqual(texts(r, .keyword), ["SELECT", "FROM"])
    }

    func testSQLBlockComment() {
        XCTAssertEqual(toks("/* x */", "sql"), [Tok(.comment, "/* x */")])
    }

    func testSQLDoubledQuoteIsAnEscapeSoItsOneString() {
        XCTAssertEqual(toks("'it''s'", "sql"), [Tok(.string, "'it''s'")])
    }

    func testSQLStringsMaySpanLines() {
        XCTAssertEqual(toks("'a\nb'", "sql"), [Tok(.string, "'a\nb'")])
    }

    func testSQLQuotedIdentifiersAreNotKeywordsAndGetNoToken() {
        XCTAssertEqual(toks("\"select\"", "sql"), [])
        XCTAssertEqual(toks("`from`", "sql"), [])
        XCTAssertEqual(texts(toks("SELECT \"from\" FROM `where`", "sql"), .keyword), ["SELECT", "FROM"])
    }

    func testSQLKeywordsAreCaseInsensitive() {
        for word in ["select", "SELECT", "Select"] {
            XCTAssertEqual(toks(word, "sql"), [Tok(.keyword, word)], word)
        }
    }

    func testSQLNullTrueFalseAreLiterals() {
        XCTAssertEqual(texts(toks("NULL TRUE FALSE", "sql"), .literal), ["NULL", "TRUE", "FALSE"])
    }

    func testSQLDoubleDashInsideAWordStartsACommentWhichIsCorrectSQL() {
        XCTAssertEqual(toks("x--y", "sql"), [Tok(.comment, "--y")])
    }

    func testSQLUnterminatedStringGivesNoStringTokenAndLaterKeywordsStillColour() {
        let r = toks("SELECT 'abc\nFROM t\nWHERE x = 1", "sql")
        XCTAssertEqual(texts(r, .string), [])
        XCTAssertEqual(texts(r, .keyword), ["SELECT", "FROM", "WHERE"])
    }

    func testSQLUnterminatedBlockCommentGivesNoCommentToken() {
        let r = toks("SELECT 1 /* never closed\nFROM t", "sql")
        XCTAssertEqual(texts(r, .comment), [])
        XCTAssertEqual(texts(r, .keyword), ["SELECT", "FROM"])
    }

    // MARK: PHP

    func testPHPOpenAndCloseTagsAreMetaAndVariablesAreVariables() {
        let r = toks("<?php\n$x = 1;\n?>", "php")
        XCTAssertEqual(texts(r, .meta), ["<?php", "?>"])
        XCTAssertEqual(texts(r, .variable), ["$x"])
    }

    func testPHPShortEchoTagIsMeta() {
        let r = toks("<?= $a ?>", "php")
        XCTAssertEqual(texts(r, .meta), ["<?=", "?>"])
        XCTAssertEqual(texts(r, .variable), ["$a"])
    }

    func testPHPDollarNameIsAVariable() {
        XCTAssertEqual(toks("$referral", "php"), [Tok(.variable, "$referral")])
    }

    func testPHPAttributeOpenerIsMetaAndNotAComment() {
        let r = toks("#[Attr]\nclass A {}", "php")
        XCTAssertEqual(texts(r, .comment), [])
        XCTAssertEqual(texts(r, .meta), ["#["])
        XCTAssertTrue(texts(r, .keyword).contains("class"))
    }

    func testPHPHashAndSlashSlashAndBlockCommentsAreComments() {
        XCTAssertEqual(toks("# c", "php"), [Tok(.comment, "# c")])
        XCTAssertEqual(toks("// c", "php"), [Tok(.comment, "// c")])
        XCTAssertEqual(toks("/* c */", "php"), [Tok(.comment, "/* c */")])
    }

    func testPHPKeywordsAreCaseInsensitive() {
        for word in ["class", "CLASS", "Class"] {
            XCTAssertEqual(texts(toks(word, "php"), .keyword), [word], word)
        }
    }

    func testPHPQuotedStringsMaySpanLines() {
        XCTAssertEqual(toks("'a\nb'", "php"), [Tok(.string, "'a\nb'")])
        XCTAssertEqual(toks("\"a\nb\"", "php"), [Tok(.string, "\"a\nb\"")])
    }

    func testPHPHeredocWithIndentedCloserIsOneString() {
        let code = "$x = <<<EOT\n  hello\n    EOT;\nif ($x) {}"
        let r = toks(code, "php")
        let strings = texts(r, .string)
        XCTAssertEqual(strings.count, 1)
        XCTAssertTrue(strings.first?.contains("hello") ?? false)
        // The closer ended the string: the `if` after it is a keyword, not swallowed.
        XCTAssertTrue(texts(r, .keyword).contains("if"))
        XCTAssertEqual(texts(r, .variable), ["$x", "$x"])
    }

    func testPHPQuotedHeredocIdentifierIsOneString() {
        let r = toks("$x = <<<\"EOT\"\nhello\nEOT;\nif (1) {}", "php")
        XCTAssertEqual(texts(r, .string).count, 1)
        XCTAssertTrue(texts(r, .keyword).contains("if"))
    }

    func testPHPHeredocCloserMustNotBeFollowedByIdentifierCharacters() {
        let r = toks("$x = <<<EOT\nEOTX still body\n  EOT;\nif (1) {}", "php")
        let strings = texts(r, .string)
        XCTAssertEqual(strings.count, 1)
        XCTAssertTrue(strings.first?.contains("EOTX still body") ?? false)
        XCTAssertTrue(texts(r, .keyword).contains("if"))
    }

    func testPHPNowdocIsOneStringAndNothingInsideIsAVariable() {
        let r = toks("$s = <<<'EOT'\nraw $notvar\nEOT;\nif (1) {}", "php")
        let strings = texts(r, .string)
        XCTAssertEqual(strings.count, 1)
        XCTAssertTrue(strings.first?.contains("raw $notvar") ?? false)
        XCTAssertEqual(texts(r, .variable), ["$s"])
        XCTAssertTrue(texts(r, .keyword).contains("if"))
    }

    func testPHPReportedMessageBlocksColourVariablesNumbersAndSQL() throws {
        let blocks = MarkdownFences.segments(of: MarkdownFenceFixtures.reportedMessage).compactMap { segment -> MarkdownFences.CodeBlock? in
            if case .code(let block) = segment { return block }
            return nil
        }
        let php = try XCTUnwrap(blocks.first { $0.language == "php" })
        let r = toks(php.code, php.language)
        XCTAssertEqual(texts(r, .variable), ["$referral", "$result", "$referral", "$result"])
        XCTAssertTrue(texts(r, .number).contains("14464"))

        let sql = try XCTUnwrap(blocks.first { $0.language == "sql" })
        let s = toks(sql.code, sql.language)
        XCTAssertTrue(texts(s, .keyword).contains("SELECT"))
        XCTAssertTrue(texts(s, .keyword).contains("FROM"))
        XCTAssertTrue(texts(s, .string).contains("'-'"))
    }

    // MARK: Bash

    func testBashDollarHashIsAVariableAndOnlyTheSecondHashStartsTheComment() {
        let r = toks("echo $# # real comment", "bash")
        XCTAssertEqual(texts(r, .variable), ["$#"])
        XCTAssertEqual(texts(r, .comment), ["# real comment"])
    }

    func testBashHashInsideParameterExpansionIsNotAComment() {
        XCTAssertEqual(texts(toks("echo ${#arr[@]}", "bash"), .comment), [])
    }

    func testBashHashInsideAWordIsPlain() {
        XCTAssertEqual(toks("a#b", "bash"), [])
    }

    func testBashHashAfterSemicolonStartsAComment() {
        XCTAssertEqual(texts(toks("a;#c", "bash"), .comment), ["#c"])
    }

    func testBashHashAtLineStartIsAComment() {
        XCTAssertEqual(toks("# top\nls", "sh"), [Tok(.comment, "# top")])
    }

    func testBashSpecialAndNamedVariables() {
        let r = toks("echo $1 $? $@ $$ $! $name ${x}", "bash")
        XCTAssertEqual(texts(r, .variable), ["$1", "$?", "$@", "$$", "$!", "$name", "${x}"])
    }

    func testBashCommandSubstitutionOpenerIsTheVariableAndTheCommandIsScannedNormally() {
        let r = toks("echo $(date) # c", "bash")
        XCTAssertEqual(texts(r, .variable), ["$("])
        XCTAssertEqual(texts(r, .comment), ["# c"])
    }

    func testBashNestedQuotesInsideSubstitutionInsideDoubleQuotesAreOneString() {
        let code = "\"$(echo \"x\")\""
        XCTAssertEqual(toks(code, "bash"), [Tok(.string, code)])
    }

    func testBashSingleQuotesHaveNoEscapesAndMaySpanLines() {
        XCTAssertEqual(toks("echo 'a\nb $x'", "bash"), [Tok(.string, "'a\nb $x'")])
        XCTAssertEqual(texts(toks("'a\\' b", "bash"), .string), ["'a\\'"])
    }

    func testBashDollarSingleQuoteAndDoubleQuoteStringsHonourBackslashEscapes() {
        XCTAssertEqual(toks("$'a\\'b'", "bash"), [Tok(.string, "$'a\\'b'")])
        XCTAssertEqual(toks("\"a \\\" b\"", "bash"), [Tok(.string, "\"a \\\" b\"")])
    }

    func testBashQuotedHeredocBodyIsAStringWithNoVariables() {
        let r = toks("cat <<'EOF'\nline $x\nEOF\nfi", "bash")
        let strings = texts(r, .string)
        XCTAssertEqual(strings.count, 1)
        XCTAssertTrue(strings.first?.contains("line $x") ?? false)
        XCTAssertEqual(texts(r, .variable), [])
        XCTAssertEqual(texts(r, .keyword), ["fi"])
    }

    func testBashPlainAndDoubleQuotedHeredocIdentifiers() {
        for opener in ["<<EOF", "<<\"EOF\""] {
            let r = toks("cat \(opener)\nhello\nEOF\nfi", "bash")
            XCTAssertEqual(texts(r, .string).count, 1, opener)
            XCTAssertEqual(texts(r, .keyword), ["fi"], opener)
        }
    }

    func testBashHeredocCloserMustEqualTheIdentifierExactly() {
        let r = toks("cat <<EOF\nEOF2\nEOF\nfi", "bash")
        let strings = texts(r, .string)
        XCTAssertEqual(strings.count, 1)
        XCTAssertTrue(strings.first?.contains("EOF2") ?? false)
        XCTAssertEqual(texts(r, .keyword), ["fi"])
    }

    func testBashDashHeredocAcceptsATabIndentedCloser() {
        let r = toks("cat <<-EOF\n\tbody\n\tEOF\nfi", "bash")
        let strings = texts(r, .string)
        XCTAssertEqual(strings.count, 1)
        XCTAssertTrue(strings.first?.contains("body") ?? false)
        XCTAssertEqual(texts(r, .keyword), ["fi"])
    }

    func testBashHereStringIsNotAHeredoc() {
        XCTAssertEqual(toks("cat <<< \"$x\"", "bash"), [Tok(.string, "\"$x\"")])
    }

    func testBashKeywordsAndTrueAreHighlighted() {
        let r = toks("if true; then echo; fi", "bash")
        XCTAssertEqual(texts(r, .keyword), ["if", "then", "fi"])
        XCTAssertEqual(texts(r, .literal), ["true"])
    }

    // MARK: JSON

    func testJSONKeysStringsNumbersAndLiterals() {
        let code = #"{"a": "b", "n": -1.5e3, "t": true, "z": null}"#
        XCTAssertEqual(toks(code, "json"), [
            Tok(.key, "\"a\""), Tok(.string, "\"b\""),
            Tok(.key, "\"n\""), Tok(.number, "-1.5e3"),
            Tok(.key, "\"t\""), Tok(.literal, "true"),
            Tok(.key, "\"z\""), Tok(.literal, "null"),
        ])
    }

    func testJSONKeyIsAStringFollowedByOptionalWhitespaceThenColon() {
        XCTAssertEqual(toks("{\"a\"   : 1}", "json"), [Tok(.key, "\"a\""), Tok(.number, "1")])
    }

    func testJSONEscapedQuoteDoesNotEndTheString() {
        XCTAssertEqual(toks(#"["a\"b"]"#, "json"), [Tok(.string, #""a\"b""#)])
        XCTAssertEqual(toks(#"{"a\"b": 1}"#, "json"), [Tok(.key, #""a\"b""#), Tok(.number, "1")])
    }

    func testJSONCommentsAreToleratedForJSONC() {
        let r = toks("{\"a\": 1 // c\n}", "jsonc")
        XCTAssertEqual(texts(r, .comment), ["// c"])
        XCTAssertEqual(toks("/* c */", "json"), [Tok(.comment, "/* c */")])
    }

    func testJSONUnterminatedStringDoesNotColourPastItsLine() {
        let r = toks("{\"a: 1,\n\"b\": true}", "json")
        XCTAssertEqual(texts(r, .literal), ["true"])
        XCTAssertTrue(texts(r, .key).contains("\"b\""))
    }

    // MARK: YAML

    func testYAMLKeyAndTrailingComment() {
        let r = toks("key: value # c", "yaml")
        XCTAssertEqual(keyNames(r), ["key"])
        XCTAssertEqual(texts(r, .comment), ["# c"])
    }

    func testYAMLHashInsideAValueWithoutPrecedingSpaceIsNotAComment() {
        XCTAssertEqual(texts(toks("url: http://x#frag", "yaml"), .comment), [])
    }

    func testYAMLHashAtLineStartIsAComment() {
        XCTAssertEqual(texts(toks("# top\nk: v", "yml"), .comment), ["# top"])
    }

    func testYAMLAnchorsAliasesAndTagsAreMeta() {
        XCTAssertEqual(texts(toks("base: &b {x: 1}\n<<: *b", "yaml"), .meta), ["&b", "*b"])
        XCTAssertEqual(texts(toks("a: !!str 1\nb: !tag x", "yaml"), .meta), ["!!str", "!tag"])
    }

    func testYAMLKeyAfterListDash() {
        XCTAssertEqual(keyNames(toks("- name: x", "yaml")), ["name"])
        XCTAssertEqual(keyNames(toks("items:\n  - name: x\n    id: 1", "yaml")), ["items", "name", "id"])
    }

    func testYAMLDocumentMarkersOnTheirOwnLineAreMeta() {
        XCTAssertEqual(toks("---", "yaml"), [Tok(.meta, "---")])
        XCTAssertEqual(texts(toks("---\nk: v\n...", "yaml"), .meta), ["---", "..."])
    }

    func testYAMLSingleQuotedStringWithDoubledQuoteEscape() {
        XCTAssertEqual(texts(toks("k: 'it''s'", "yaml"), .string), ["'it''s'"])
    }

    func testYAMLDoubleQuotedString() {
        XCTAssertEqual(texts(toks("k: \"a b\"", "yaml"), .string), ["\"a b\""])
    }

    func testYAMLLiteralsWhenTheyAreTheWholeValueAndNumbers() {
        let r = toks("a: true\nb: Null\nc: ~\nd: off", "yaml")
        XCTAssertEqual(texts(r, .literal), ["true", "Null", "~", "off"])
        XCTAssertEqual(texts(toks("n: 42", "yaml"), .number), ["42"])
        XCTAssertEqual(texts(toks("msg: true story", "yaml"), .literal), [])
    }

    func testYAMLBlockScalarBodyIsAString() {
        let code = "text: |\n  line one\n  line two\nnext: 1"
        XCTAssertTrue(isCovered("line one", in: code, "yaml", by: .string))
        XCTAssertTrue(isCovered("line two", in: code, "yaml", by: .string))
        let r = toks(code, "yaml")
        XCTAssertEqual(keyNames(r), ["text", "next"])
        XCTAssertFalse(texts(r, .string).contains { $0.contains("next") })
        XCTAssertEqual(texts(r, .number), ["1"])
    }

    func testYAMLFoldedAndChompedBlockScalarIndicators() {
        for indicator in [">", "|-", ">+"] {
            let code = "t: \(indicator)\n  body text\nnext: 1"
            XCTAssertTrue(isCovered("body text", in: code, "yaml", by: .string), indicator)
            XCTAssertEqual(keyNames(toks(code, "yaml")), ["t", "next"], indicator)
        }
    }

    // MARK: Swift

    func testSwiftStructIsAKeywordAndItsCapitalisedNameIsAType() {
        XCTAssertEqual(toks("struct Foo", "swift"), [Tok(.keyword, "struct"), Tok(.type, "Foo")])
    }

    func testSwiftLetAndNilAndNumbers() {
        XCTAssertEqual(toks("let x = nil", "swift"), [Tok(.keyword, "let"), Tok(.literal, "nil")])
        XCTAssertEqual(texts(toks("0xFF_ff 1_000 1.5e3 0b101 0o7", "swift"), .number),
                       ["0xFF_ff", "1_000", "1.5e3", "0b101", "0o7"])
    }

    func testSwiftDigitsInsideAnIdentifierAreNotANumber() {
        XCTAssertEqual(toks("x1 + y2", "swift"), [])
    }

    func testSwiftMultilineStringWithInterpolationAndQuotesIsOneString() {
        assertOneString("\"\"\"\nline \\(x) \"q\"\n\"\"\"", "swift")
    }

    func testSwiftRawStringIsOneStringIgnoringPlainInterpolationAndInnerQuotes() {
        assertOneString("#\"raw \\(not) \"quoted\"\"#", "swift")
    }

    func testSwiftRawStringInterpolationUsesHashedBackslash() {
        assertOneString("#\"a \\#(x) b\"#", "swift")
        assertOneString("##\"a \"# b \\##(x)\"##", "swift")
    }

    func testSwiftInterpolationWithANestedStringIsOneString() {
        assertOneString("\"a \\(f(\"b\")) c\"", "swift")
    }

    func testSwiftNestedBlockCommentIsOneComment() {
        XCTAssertEqual(toks("/* /* */ */", "swift"), [Tok(.comment, "/* /* */ */")])
        XCTAssertEqual(toks("// c", "swift"), [Tok(.comment, "// c")])
    }

    func testSwiftAttributeIsMeta() {
        XCTAssertEqual(toks("@MainActor", "swift"), [Tok(.meta, "@MainActor")])
    }

    func testSwiftConditionalCompilationDirectivesAreMeta() {
        let r = toks("#if DEBUG\n#else\n#endif", "swift")
        let metas = texts(r, .meta)
        XCTAssertEqual(metas.count, 3)
        XCTAssertTrue(metas[0].hasPrefix("#if"))
        XCTAssertTrue(metas[1].hasPrefix("#else"))
        XCTAssertTrue(metas[2].hasPrefix("#endif"))
    }

    func testSwiftUnterminatedStringDoesNotColourPastItsLine() {
        let r = toks("let s = \"abc\nlet t = 1", "swift")
        XCTAssertEqual(texts(r, .string), [])
        XCTAssertEqual(texts(r, .keyword), ["let", "let"])
        XCTAssertEqual(texts(r, .number), ["1"])
    }

    func testSwiftUnterminatedBlockCommentGivesNoCommentToken() {
        let r = toks("/* a\nlet x = 1", "swift")
        XCTAssertEqual(texts(r, .comment), [])
        XCTAssertEqual(texts(r, .keyword), ["let"])
    }

    // MARK: Rust

    func testRustLifetimesAreTypesAndTheCharLiteralIsAString() {
        let r = toks("fn f<'a>(x: &'a str) -> char { 'x' }", "rust")
        XCTAssertEqual(r.filter { $0.text == "'a" }.map(\.kind), [.type, .type])
        XCTAssertEqual(texts(r, .string), ["'x'"])
        XCTAssertTrue(texts(r, .keyword).contains("fn"))
    }

    func testRustStaticLifetimeAndBareLifetime() {
        XCTAssertEqual(toks("&'static str", "rust").first { $0.text == "'static" }?.kind, .type)
        XCTAssertEqual(toks("'ab", "rust"), [Tok(.type, "'ab")])
        XCTAssertEqual(toks("' ", "rust"), [])
    }

    func testRustEscapedAndUnicodeCharLiteralsAreStrings() {
        for literal in ["'\\n'", "'\\u{1F600}'", "'\\''", "'\\x41'", "'a'", "'\u{E9}'", "'\u{1F600}'"] {
            XCTAssertEqual(toks(literal, "rust"), [Tok(.string, literal)], literal)
        }
    }

    func testRustRawStringsAreOneString() {
        assertOneString("r#\"he said \"hi\"\"#", "rust")
        assertOneString("br#\"a\"b\"#", "rust")
        assertOneString("r\"a\\b\"", "rust")
        assertOneString("b\"x\"", "rust")
        assertOneString("\"a\\\"b\"", "rust")
    }

    func testRustAttributesAreMeta() {
        XCTAssertEqual(toks("#[derive(Debug)]", "rust"), [Tok(.meta, "#[derive(Debug)]")])
        XCTAssertEqual(toks("#![allow(dead_code)]", "rust"), [Tok(.meta, "#![allow(dead_code)]")])
    }

    func testRustAttributeWithoutClosingBracketOnItsLineIsJustTheOpener() {
        XCTAssertEqual(texts(toks("#[derive(Debug\nfn", "rust"), .meta), ["#["])
    }

    func testRustNestedBlockCommentsAreOneComment() {
        let r = toks("/* a /* b */ c */ fn", "rust")
        XCTAssertEqual(texts(r, .comment), ["/* a /* b */ c */"])
        XCTAssertEqual(texts(r, .keyword), ["fn"])
    }

    func testRustNumberWithTypeSuffixIsOneNumber() {
        XCTAssertEqual(toks("1u8", "rust"), [Tok(.number, "1u8")])
    }

    func testRustKeywordsAndCapitalisedTypes() {
        let r = toks("fn main() { let mut x = true; }", "rust")
        XCTAssertEqual(texts(r, .keyword), ["fn", "let", "mut"])
        XCTAssertEqual(texts(r, .literal), ["true"])
        XCTAssertTrue(texts(toks("Vec<String>", "rust"), .type).contains("Vec"))
    }

    // MARK: Python

    func testPythonTripleQuotedStringSpansLines() {
        assertOneString("'''a\n\"b\"\n'''", "python")
        assertOneString("\"\"\"a\n'b'\n\"\"\"", "python")
    }

    func testPythonFStringWithNestedSameQuoteAndEscapedBracesIsOneString() {
        assertOneString("f\"{x[\"k\"]} {{lit}}\"", "python")
    }

    func testPythonStringPrefixesAreCaseInsensitive() {
        for literal in ["rb'\\d'", "Rb'\\d'", "u'x'", "R\"x\"", "BR'x'"] {
            assertOneString(literal, "py")
        }
    }

    func testPythonHashIsAComment() {
        XCTAssertEqual(toks("# c", "python"), [Tok(.comment, "# c")])
        XCTAssertEqual(texts(toks("x = 1  # c", "python3"), .comment), ["# c"])
    }

    func testPythonDecoratorAtLineStartIsMetaButMatmulIsNot() {
        XCTAssertEqual(toks("@dataclass", "python"), [Tok(.meta, "@dataclass")])
        XCTAssertEqual(texts(toks("a @b", "python"), .meta), [])
    }

    func testPythonNoneTrueFalseAreLiterals() {
        XCTAssertEqual(toks("None", "python"), [Tok(.literal, "None")])
        XCTAssertEqual(texts(toks("True False", "python"), .literal), ["True", "False"])
    }

    func testPythonKeywords() {
        let r = toks("def f(x): return None", "python")
        XCTAssertEqual(texts(r, .keyword), ["def", "return"])
        XCTAssertEqual(texts(r, .literal), ["None"])
    }

    func testPythonUnterminatedTripleQuoteGivesNoStringAndLaterCodeStillColours() {
        let r = toks("'''a\nNone", "python")
        XCTAssertEqual(texts(r, .string), [])
        XCTAssertEqual(texts(r, .literal), ["None"])
    }

    func testPythonSingleQuotedStringsAreSingleLine() {
        let r = toks("x = 'abc\ny = \"z\"", "python")
        XCTAssertEqual(texts(r, .string), ["\"z\""])
    }

    // MARK: JavaScript / TypeScript

    func testJSNestedTemplateLiteralsAreOneString() {
        assertOneString("`a ${b + `c ${d}`} e`", "js")
    }

    func testJSTemplateLiteralMaySpanLines() {
        assertOneString("`a\nb`", "js")
    }

    func testJSLineCommentAndKeywords() {
        XCTAssertEqual(toks("// c", "js"), [Tok(.comment, "// c")])
        XCTAssertEqual(texts(toks("const x = 1;", "javascript"), .keyword), ["const"])
        XCTAssertEqual(texts(toks("true false null undefined", "js"), .literal),
                       ["true", "false", "null", "undefined"])
    }

    func testJSDollarIsPartOfAnIdentifier() {
        XCTAssertEqual(toks("$y + _z", "js"), [])
    }

    func testTSKeywordsAreRecognisedUnderTheTypeScriptAliases() {
        XCTAssertEqual(texts(toks("interface X {}", "ts"), .keyword), ["interface"])
        XCTAssertEqual(texts(toks("type A = string", "typescript"), .keyword), ["type"])
        XCTAssertEqual(texts(toks("enum E {}", "tsx"), .keyword), ["enum"])
    }

    func testJSCapitalisedIdentifierWithLowercaseIsAType() {
        XCTAssertEqual(toks("new Foo()", "js"), [Tok(.keyword, "new"), Tok(.type, "Foo")])
    }

    func testJSRegexLiteralQuoteNeverColoursPastItsLine() {
        let code = "const re = /\"/;\nconst s = 'ok';"
        let r = toks(code, "js")
        XCTAssertEqual(texts(r, .string), ["'ok'"])
        XCTAssertEqual(texts(r, .keyword), ["const", "const"])
    }

    func testJSUnterminatedQuoteDoesNotColourPastItsLine() {
        let r = toks("x = 'abc\nlet y = \"z\"", "js")
        XCTAssertEqual(texts(r, .string), ["\"z\""])
        XCTAssertEqual(texts(r, .keyword), ["let"])
    }

    func testJSUnterminatedTemplateLiteralGivesNoStringAndLaterCodeStillColours() {
        let r = toks("`abc\nlet y = 1", "js")
        XCTAssertEqual(texts(r, .string), [])
        XCTAssertEqual(texts(r, .keyword), ["let"])
    }

    // MARK: diff

    func testTwoFileDiffClassifiesHeadersHunksAndChanges() {
        let lines = [
            "diff --git a/a.txt b/a.txt",
            "index 111..222 100644",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -1,2 +1,2 @@",
            " context",
            "-old",
            "+new",
            "diff --git a/b.txt b/b.txt",
            "--- a/b.txt",
            "+++ b/b.txt",
            "@@ -1 +1 @@",
            "-x",
            "+y",
        ]
        let expected: [Tok] = [
            Tok(.meta, lines[0]), Tok(.meta, lines[1]), Tok(.meta, lines[2]), Tok(.meta, lines[3]),
            Tok(.meta, lines[4]),
            Tok(.deleted, "-old"), Tok(.inserted, "+new"),
            Tok(.meta, lines[8]), Tok(.meta, lines[9]), Tok(.meta, lines[10]), Tok(.meta, lines[11]),
            Tok(.deleted, "-x"), Tok(.inserted, "+y"),
        ]
        XCTAssertEqual(toks(lines.joined(separator: "\n"), "diff"), expected)
    }

    func testDiffDashDashDashLineAfterTheFirstHunkIsDeletedNotMeta() {
        let code = "@@ -1 +1 @@\n--- x\n+++ y"
        XCTAssertEqual(toks(code, "diff"), [
            Tok(.meta, "@@ -1 +1 @@"), Tok(.deleted, "--- x"), Tok(.inserted, "+++ y"),
        ])
    }

    func testDiffFileModeAndRenameLinesAreMeta() {
        let lines = ["new file mode 100644", "deleted file mode 100644", "similarity index 90%",
                     "rename from a", "rename to b"]
        XCTAssertEqual(toks(lines.joined(separator: "\n"), "patch"), lines.map { Tok(.meta, $0) })
    }

    func testDiffNoNewlineMarkerIsMeta() {
        XCTAssertEqual(toks("-a\n\\ No newline at end of file\n+b", "diff"), [
            Tok(.deleted, "-a"), Tok(.meta, "\\ No newline at end of file"), Tok(.inserted, "+b"),
        ])
    }

    func testDiffTokensCoverTheWholeLineExcludingTheNewline() {
        let r = toks("+a b // c\n-d 'e", "diff")
        XCTAssertEqual(r, [Tok(.inserted, "+a b // c"), Tok(.deleted, "-d 'e")])
    }

    // MARK: Language resolution

    func testMissingEmptyUnknownAndPlainLanguagesProduceNoTokens() {
        let code = "SELECT 1 -- x\nlet x = 1\n+added"
        for language in [nil, "", "cobol", "text", "plain", "txt", "plaintext"] as [String?] {
            XCTAssertEqual(SyntaxHighlighter.tokens(in: code, language: language), [],
                           "language \(String(describing: language))")
        }
    }

    func testEveryDocumentedAliasResolvesToALanguage() {
        let table: [(sample: String, ids: [String])] = [
            ("select", ["sql", "mysql", "postgres", "postgresql", "psql", "sqlite", "plpgsql"]),
            ("<?php", ["php"]),
            ("if", ["bash", "sh", "zsh", "shell"]),
            ("true", ["json", "jsonc", "json5"]),
            ("a: 1", ["yaml", "yml"]),
            ("struct", ["swift"]),
            ("fn", ["rust", "rs"]),
            ("None", ["python", "py", "python3"]),
            ("const", ["js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx"]),
            ("+x", ["diff", "patch"]),
        ]
        for (sample, ids) in table {
            for id in ids {
                XCTAssertFalse(SyntaxHighlighter.tokens(in: sample, language: id).isEmpty,
                               "alias \(id) should resolve (sample \(sample.debugDescription))")
            }
        }
    }

    func testLanguageNamesResolveCaseInsensitively() {
        XCTAssertEqual(toks("select", "SQL"), [Tok(.keyword, "select")])
        XCTAssertEqual(toks("# c", "Py"), [Tok(.comment, "# c")])
        XCTAssertEqual(toks("// c", "TSX"), [Tok(.comment, "// c")])
    }

    func testFenceInfoStringWithAttributesStillHighlightsAsItsLanguage() throws {
        let text = "```js title=\"x\"\nconst a = 1\n```"
        guard case .code(let block)? = MarkdownFences.segments(of: text).first(where: {
            if case .code = $0 { return true }
            return false
        }) else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(block.language, "js")
        let r = toks(block.code, block.language)
        XCTAssertEqual(texts(r, .keyword), ["const"])
        XCTAssertEqual(texts(r, .number), ["1"])
    }
}
