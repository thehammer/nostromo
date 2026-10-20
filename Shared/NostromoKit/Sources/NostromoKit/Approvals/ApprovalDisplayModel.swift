// NostromoKit — ApprovalDisplayModel.swift
//
// Turns the daemon's `ApprovalDisplay` (design contract §4.3) into what the
// approval card draws, and **re-checks the round-trip invariant (T-INV-2)**
// against the request's raw `input`: putting every invisible segment back as its
// code point and joining the lines must give the original text exactly. If it
// doesn't, the card disables Allow (`roundTripFailureLabel`): a person must
// never approve text that isn't the text that would run.
//
// Nothing here elides, rewrites or reorders text. The check is byte-exact
// (UTF-8), not Swift's `==`, which treats canonically equivalent strings (é as
// one scalar or two) as equal.
//
// Pure value types, no AppKit.

import Foundation

// MARK: - Runs and lines

/// What a run of text is, for colouring.
public enum ApprovalRunKind: Equatable {
    case plain
    case separator
    case invisible
    case nonAscii
}

/// One run of text inside a display line.
public struct ApprovalRenderRun: Equatable {
    /// What is shown: for an invisible character its token (`⟨U+202E RLO⟩`).
    public let text: String
    public let kind: ApprovalRunKind
    /// The code point of an invisible or non-ASCII run.
    public let codePoint: UInt32?

    /// The text as it was in the request: an invisible run is its character again.
    public var original: String {
        if kind == .invisible, let cp = codePoint, let scalar = Unicode.Scalar(cp) {
            return String(Character(scalar))
        }
        return text
    }

    /// Hover text for a non-ASCII character: `U+043C CYRILLIC SMALL LETTER EM`.
    public var tooltip: String? {
        guard kind == .nonAscii, let cp = codePoint else { return nil }
        return ApprovalDisplayModel.describe(codePoint: cp)
    }

    /// What VoiceOver reads for this run: an invisible character by name
    /// (`RIGHT-TO-LEFT OVERRIDE (U+202E)`), everything else as written.
    public var spoken: String {
        guard kind == .invisible, let cp = codePoint else { return text }
        switch cp {
        case 0x09: return "tab"
        case 0x0D: return "carriage return"
        default: return ApprovalDisplayModel.describe(codePoint: cp, nameFirst: true)
        }
    }
}

/// One numbered line of the display.
public struct ApprovalRenderLine: Equatable {
    public let number: Int
    public let kind: ApprovalLineKind
    /// Continues the previous line after a separator cut (no newline in the original).
    public let cont: Bool
    public let runs: [ApprovalRenderRun]

    /// The line as shown: invisible characters as tokens, nothing else changed.
    public var text: String { runs.map(\.text).joined() }

    /// The line as shown, with each separator wrapped in `⟨ ⟩` (`rm -rf build/ ⟨&&⟩`).
    public var markedText: String {
        runs.map { $0.kind == .separator ? "\u{27E8}\($0.text)\u{27E9}" : $0.text }.joined()
    }

    /// The separators on this line (`&&`, `|`, `;`), in order.
    public var separators: [String] { runs.filter { $0.kind == .separator }.map(\.text) }

    /// The line as spoken: invisible characters by name, spaced off from the text around them
    /// so a screen reader doesn't run a name into a word.
    public var spokenText: String {
        var out = ""
        for run in runs {
            if run.kind == .invisible {
                if !out.isEmpty && !out.hasSuffix(" ") { out += " " }
                out += run.spoken + " "
            } else {
                out += run.text
            }
        }
        return out
    }
}

public enum ApprovalRoundTrip: Equatable {
    case verified
    case mismatch(String)
}

// MARK: - The model

public struct ApprovalDisplayModel: Equatable {

    /// What Allow says while the round-trip check fails.
    public static let roundTripFailureLabel = "Nostromo couldn't verify this text matches the request"

    /// The daemon's display lines: what the round-trip check covers.
    public let lines: [ApprovalRenderLine]
    /// Bash only: every field of the input other than `command` (and a `description` that is
    /// the agent's claim shown separately), as JSON lines built here from the input itself,
    /// so a flag like `dangerouslyDisableSandbox` is never approved unseen. Numbered after `lines`.
    public let extraLines: [ApprovalRenderLine]
    public let commandCount: Int?
    /// Counted from the segments themselves, never trusted from the frame.
    public let invisibleCount: Int
    public let nonAsciiCount: Int
    public let unparsed: Bool
    public let roundTrip: ApprovalRoundTrip

    public var isVerified: Bool { roundTrip == .verified }

    /// Everything the card shows as input: the display lines, then any extra fields.
    public var allLines: [ApprovalRenderLine] { lines + extraLines }

    public init(request: ApprovalRequestWire) {
        let display = request.display
        var lines: [ApprovalRenderLine] = []
        lines.reserveCapacity(display.lines.count)
        var invisible = 0
        var nonAscii = 0
        for line in display.lines {
            let runs = line.segments.map { seg -> ApprovalRenderRun in
                switch seg.kind {
                case .invisible:
                    invisible += 1
                    return ApprovalRenderRun(text: seg.text, kind: .invisible, codePoint: seg.cp)
                case .nonAscii:
                    nonAscii += 1
                    return ApprovalRenderRun(text: seg.text, kind: .nonAscii, codePoint: seg.cp)
                case .separator:
                    return ApprovalRenderRun(text: seg.text, kind: .separator, codePoint: nil)
                case .plain, .unknown:
                    return ApprovalRenderRun(text: seg.text, kind: .plain, codePoint: nil)
                }
            }
            lines.append(ApprovalRenderLine(number: line.number, kind: line.kind, cont: line.cont, runs: runs))
        }
        let extras = Self.extraLines(for: request, startingAt: lines.count + 1)
        for run in extras.flatMap(\.runs) {
            if run.kind == .invisible { invisible += 1 } else if run.kind == .nonAscii { nonAscii += 1 }
        }
        self.lines = lines
        self.extraLines = extras
        self.commandCount = display.commandCount
        self.invisibleCount = invisible
        self.nonAsciiCount = nonAscii
        self.unparsed = display.unparsed
        self.roundTrip = Self.check(lines: lines, toolKind: request.toolKind, input: request.input)
    }

    // MARK: Text

    /// The input as displayed, readable: invisible characters as tokens, lines joined
    /// as in the original (no newline at a separator cut). With each token put back as
    /// its code point this is the request's text exactly.
    public var shownText: String {
        var out = ""
        for (i, line) in lines.enumerated() {
            if i > 0 && !line.cont { out += "\n" }
            out += line.text
        }
        return out
    }

    /// The first command (or first line) as shown, for button labels:
    /// everything before the first separator of the first line.
    public var summary: String {
        guard let first = lines.first else { return "" }
        var text = ""
        for run in first.runs {
            if run.kind == .separator { break }
            text += run.text
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `This command contains N invisible or direction-changing characters.`; nil when none.
    public func banner(toolKind: ApprovalToolKind) -> String? {
        guard invisibleCount > 0 else { return nil }
        let noun = toolKind == .bash ? "command" : "input"
        let what = invisibleCount == 1 ? "1 invisible or direction-changing character"
                                       : "\(invisibleCount) invisible or direction-changing characters"
        return "This \(noun) contains \(what)."
    }

    // MARK: Extra fields of a Bash input

    private static func extraLines(for request: ApprovalRequestWire, startingAt first: Int) -> [ApprovalRenderLine] {
        guard request.toolKind == .bash, case .object(var fields) = request.input,
              case .string? = fields["command"] else { return [] }
        fields["command"] = nil
        if case .string(let text)? = fields["description"], let claim = request.description,
           bytesEqual(text, claim) {
            fields["description"] = nil
        }
        guard !fields.isEmpty else { return [] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ApprovalJSON.object(fields)),
              let pretty = String(data: data, encoding: .utf8) else {
            return [ApprovalRenderLine(number: first, kind: .unknown, cont: false,
                                       runs: [ApprovalRenderRun(text: "(other fields of this input could not be shown)",
                                                                kind: .plain, codePoint: nil)])]
        }
        var texts = ["Other fields sent with this command:"]
        texts += pretty.components(separatedBy: "\n")
        return texts.enumerated().map { i, text in
            ApprovalRenderLine(number: first + i, kind: i == 0 ? .unknown : .json, cont: false, runs: runs(for: text))
        }
    }

    /// `text` as runs, the way the daemon segments it: hidden characters become invisible
    /// runs (shown as tokens), other non-ASCII characters their own runs, the rest plain.
    private static func runs(for text: String) -> [ApprovalRenderRun] {
        var runs: [ApprovalRenderRun] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { runs.append(ApprovalRenderRun(text: plain, kind: .plain, codePoint: nil)); plain = "" }
        }
        for scalar in text.unicodeScalars {
            if isHidden(scalar) || scalar.value == 0x09 || scalar.value == 0x0D {
                flush()
                runs.append(ApprovalRenderRun(text: canonicalToken(forCodePoint: scalar.value), kind: .invisible,
                                              codePoint: scalar.value))
            } else if !scalar.isASCII {
                flush()
                runs.append(ApprovalRenderRun(text: String(Character(scalar)), kind: .nonAscii, codePoint: scalar.value))
            } else {
                plain.unicodeScalars.append(scalar)
            }
        }
        flush()
        return runs
    }

    // MARK: Unicode names

    /// `U+043C CYRILLIC SMALL LETTER EM`, or just the `U+XXXX` where Unicode has no name or alias.
    /// With `nameFirst`: `CYRILLIC SMALL LETTER EM (U+043C)`.
    public static func describe(codePoint cp: UInt32, nameFirst: Bool = false) -> String {
        let hex = String(format: "U+%04X", cp)
        guard let scalar = Unicode.Scalar(cp),
              let name = scalar.properties.name ?? scalar.properties.nameAlias, !name.isEmpty
        else { return hex }
        return nameFirst ? "\(name) (\(hex))" : "\(hex) \(name)"
    }

    // MARK: Round trip (T-INV-2)

    /// The token an invisible character is shown as: `⟨tab⟩`, `⟨CR⟩`, `⟨U+202E RLO⟩`, `⟨U+E0041⟩`.
    /// The same table as the daemon's `invisible_token` (`src/approvals/display.rs`): a run whose
    /// text is anything else is not a faithful picture of its code point.
    public static func canonicalToken(forCodePoint cp: UInt32) -> String {
        switch cp {
        case 0x09: return "\u{27E8}tab\u{27E9}"
        case 0x0D: return "\u{27E8}CR\u{27E9}"
        default:
            let hex = String(format: "U+%04X", cp)
            if let name = invisibleNames[cp] { return "\u{27E8}\(hex) \(name)\u{27E9}" }
            return "\u{27E8}\(hex)\u{27E9}"
        }
    }

    private static let invisibleNames: [UInt32: String] = [
        0x202A: "LRE", 0x202B: "RLE", 0x202C: "PDF", 0x202D: "LRO", 0x202E: "RLO",
        0x2066: "LRI", 0x2067: "RLI", 0x2068: "FSI", 0x2069: "PDI",
        0x200B: "ZWSP", 0x200C: "ZWNJ", 0x200D: "ZWJ", 0x2060: "WJ", 0xFEFF: "BOM",
        0x00AD: "SHY", 0x061C: "ALM", 0x200E: "LRM", 0x200F: "RLM",
    ]

    private static func check(lines: [ApprovalRenderLine], toolKind: ApprovalToolKind,
                              input: ApprovalJSON) -> ApprovalRoundTrip {
        // Line numbers run 1, 2, 3 … so a "line 287" means the 287th line.
        for (i, line) in lines.enumerated() where line.number != i + 1 {
            return .mismatch("line numbers are out of order at line \(line.number)")
        }
        // Each run is a faithful picture of what it stands for, and none hides a character.
        for line in lines {
            for run in line.runs {
                switch run.kind {
                case .invisible:
                    guard let cp = run.codePoint, Unicode.Scalar(cp) != nil else {
                        return .mismatch("an invisible character has no code point (line \(line.number))")
                    }
                    guard bytesEqual(run.text, canonicalToken(forCodePoint: cp)) else {
                        return .mismatch("line \(line.number) shows an invisible character as something else")
                    }
                case .nonAscii:
                    guard let cp = run.codePoint, let scalar = Unicode.Scalar(cp),
                          bytesEqual(run.text, String(Character(scalar))), !scalar.isASCII, !isHidden(scalar)
                    else { return .mismatch("line \(line.number) shows a non-ASCII character as something else") }
                case .plain, .separator:
                    if run.text.unicodeScalars.contains(where: isHidden) {
                        return .mismatch("line \(line.number) hides a character that is not marked")
                    }
                    // A non-ASCII look-alike must arrive as its own (tinted) run, never inside plain text.
                    if run.text.unicodeScalars.contains(where: { !$0.isASCII }) {
                        return .mismatch("line \(line.number) has a non-ASCII character that is not marked")
                    }
                }
            }
        }

        let fields = input.objectFields
        func string(_ key: String) -> String? {
            if case .string(let s)? = fields?[key] { return s }
            return nil
        }
        func has(_ keys: [String]) -> Bool { keys.allSatisfy { string($0) != nil } }

        switch toolKind {
        case .bash where has(["command"]):
            guard let command = string("command") else { break }
            guard lines.allSatisfy({ [.command, .heredocBody, .heredocEnd].contains($0.kind) }) else {
                return .mismatch("the display has lines that are not part of the command")
            }
            return verdict(join(lines, keeping: { _ in true }), command, "the command")
        case .edit where has(["file_path", "old_string", "new_string"]):
            return checkFile(lines, fields: fields, pathKey: "file_path",
                             known: ["file_path", "old_string", "new_string"],
                             bodyKinds: [.diffCtx, .diffDel, .diffAdd]) {
                let old = verdict(join(lines, keeping: { $0 == .diffCtx || $0 == .diffDel }), string("old_string") ?? "", "the old text")
                if old != .verified { return old }
                return verdict(join(lines, keeping: { $0 == .diffCtx || $0 == .diffAdd }), string("new_string") ?? "", "the new text")
            }
        case .write where has(["file_path", "content"]):
            return checkFile(lines, fields: fields, pathKey: "file_path", known: ["file_path", "content"],
                             bodyKinds: [.diffAdd]) {
                verdict(join(lines, keeping: { $0 == .diffAdd }), string("content") ?? "", "the content")
            }
        case .notebookEdit where has(["notebook_path"]):
            // `new_source` is accounted for only when it is a string; any other value stays an
            // extra field that must be shown as JSON (the daemon shows none, so the check fails).
            let source = string("new_source")
            return checkFile(lines, fields: fields, pathKey: "notebook_path",
                             known: source == nil ? ["notebook_path"] : ["notebook_path", "new_source"],
                             bodyKinds: [.diffAdd]) {
                verdict(join(lines, keeping: { $0 == .diffAdd }), source ?? "", "the new source")
            }
        default:
            break
        }
        return checkJSON(lines, expected: input)
    }

    /// A file tool: the first line is the path, `body` checks the text, and any other
    /// field of the input is shown as JSON lines that must be those fields.
    private static func checkFile(_ lines: [ApprovalRenderLine], fields: [String: ApprovalJSON]?,
                                  pathKey: String, known: [String], bodyKinds: Set<ApprovalLineKind>,
                                  body: () -> ApprovalRoundTrip) -> ApprovalRoundTrip {
        guard case .string(let path)? = fields?[pathKey] else { return .mismatch("the path is missing") }
        guard let header = lines.first, header.kind == .fileHeader,
              lines.filter({ $0.kind == .fileHeader }).count == 1,
              bytesEqual(header.runs.map(\.original).joined(), path)
        else { return .mismatch("the shown path is not the request's path") }
        guard lines.dropFirst().allSatisfy({ bodyKinds.contains($0.kind) || $0.kind == .json }) else {
            return .mismatch("the display has lines that are not part of this change")
        }
        let result = body()
        if result != .verified { return result }

        let extras = (fields ?? [:]).filter { !known.contains($0.key) }
        let jsonLines = lines.filter { $0.kind == .json }
        if extras.isEmpty {
            return jsonLines.isEmpty ? .verified : .mismatch("the display has fields the request does not")
        }
        return checkJSON(jsonLines, expected: .object(extras))
    }

    /// The lines must all be JSON, and joined must parse to exactly the request's JSON, with no key twice.
    private static func checkJSON(_ lines: [ApprovalRenderLine], expected: ApprovalJSON) -> ApprovalRoundTrip {
        guard lines.allSatisfy({ $0.kind == .json }) else {
            return .mismatch("the display mixes JSON with other kinds of line")
        }
        let text = join(lines, keeping: { _ in true })
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ApprovalJSON.self, from: data)
        else { return .mismatch("the shown JSON does not parse") }
        // A dictionary keeps one value per key, so a repeated key would hide the first one.
        var scanner = JSONKeyScanner(bytes: Array(text.utf8))
        if scanner.hasDuplicateKey() { return .mismatch("the shown JSON repeats a key") }
        return parsed.exactlyEquals(expected) ? .verified : .mismatch("the shown JSON differs from the request's input")
    }

    /// The text of the lines whose kind passes `keeping`: each line's original text
    /// (invisible runs as their characters), `\n` between lines but not at a `cont` cut.
    private static func join(_ lines: [ApprovalRenderLine], keeping: (ApprovalLineKind) -> Bool) -> String {
        var out = ""
        var first = true
        for line in lines where keeping(line.kind) {
            if !first && !line.cont { out += "\n" }
            first = false
            for run in line.runs { out += run.original }
        }
        return out
    }

    private static func verdict(_ shown: String, _ expected: String, _ what: String) -> ApprovalRoundTrip {
        bytesEqual(shown, expected) ? .verified : .mismatch("the shown text is not \(what) of the request")
    }

    /// Exact, byte-for-byte comparison.
    private static func bytesEqual(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// A scalar that can hide inside text: controls, format characters, line and
    /// paragraph separators, variation selectors and the code points that render blank.
    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            break
        }
        if scalar.properties.isVariationSelector { return true }
        switch scalar.value {
        case 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0:
            return true
        default:
            return false
        }
    }
}

private extension ApprovalJSON {
    /// Equal, comparing every string and every key byte for byte (Swift's `==` on `String`
    /// treats canonically equivalent text, like `é` as one scalar or two, as equal).
    func exactlyEquals(_ other: ApprovalJSON) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.string(let a), .string(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.exactlyEquals($1) }
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            return a.allSatisfy { key, value in
                b.first { $0.key.utf8.elementsEqual(key.utf8) }.map { value.exactlyEquals($0.value) } ?? false
            }
        default: return false
        }
    }

    var objectFields: [String: ApprovalJSON]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}

/// Finds a key that appears twice in one JSON object. Runs on text that already decoded, so
/// it is well formed and no deeper than the decoder allows.
private struct JSONKeyScanner {
    let bytes: [UInt8]
    private var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func hasDuplicateKey() -> Bool { value() }

    private var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

    private mutating func skipSpace() {
        while let c = peek, c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 }
    }

    /// Reads a string token (at the opening quote) and returns it decoded.
    private mutating func string() -> String? {
        let start = i
        guard peek == 0x22 else { return nil }
        i += 1
        while let c = peek {
            if c == 0x5C { i += 2; continue }
            i += 1
            if c == 0x22 { break }
        }
        guard i <= bytes.count else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(bytes[start ..< i]))
    }

    private mutating func value() -> Bool {
        skipSpace()
        switch peek {
        case 0x7B:
            i += 1
            var keys = Set<String>()
            skipSpace()
            if peek == 0x7D { i += 1; return false }
            while true {
                skipSpace()
                guard let key = string() else { return false }
                if !keys.insert(key).inserted { return true }
                skipSpace()
                guard peek == 0x3A else { return false }
                i += 1
                if value() { return true }
                skipSpace()
                if peek == 0x2C { i += 1; continue }
                if peek == 0x7D { i += 1 }
                return false
            }
        case 0x5B:
            i += 1
            skipSpace()
            if peek == 0x5D { i += 1; return false }
            while true {
                if value() { return true }
                skipSpace()
                if peek == 0x2C { i += 1; continue }
                if peek == 0x5D { i += 1 }
                return false
            }
        case 0x22:
            _ = string()
            return false
        default:
            while let c = peek, c != 0x2C, c != 0x5D, c != 0x7D, c != 0x20, c != 0x0A, c != 0x0D, c != 0x09 { i += 1 }
            return false
        }
    }
}
