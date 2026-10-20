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

    public let lines: [ApprovalRenderLine]
    public let commandCount: Int?
    /// Counted from the segments themselves, never trusted from the frame.
    public let invisibleCount: Int
    public let nonAsciiCount: Int
    public let unparsed: Bool
    public let roundTrip: ApprovalRoundTrip

    public var isVerified: Bool { roundTrip == .verified }

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
        self.lines = lines
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

    private static func check(lines: [ApprovalRenderLine], toolKind: ApprovalToolKind,
                              input: ApprovalJSON) -> ApprovalRoundTrip {
        // Line numbers run 1, 2, 3 … so a "line 287" means the 287th line.
        for (i, line) in lines.enumerated() where line.number != i + 1 {
            return .mismatch("line numbers are out of order at line \(line.number)")
        }
        // Invisible runs must carry a real code point, and no other run may hide one.
        for line in lines {
            for run in line.runs {
                if run.kind == .invisible {
                    guard let cp = run.codePoint, Unicode.Scalar(cp) != nil else {
                        return .mismatch("an invisible character has no code point (line \(line.number))")
                    }
                } else if run.text.unicodeScalars.contains(where: isHidden) {
                    return .mismatch("line \(line.number) hides a character that is not marked")
                }
            }
        }

        let fields = input.objectFields
        func string(_ key: String) -> String? {
            if case .string(let s)? = fields?[key] { return s }
            return nil
        }
        func has(_ keys: [String]) -> Bool { keys.allSatisfy { string($0) != nil } }
        let hasHeader = lines.contains { $0.kind == .fileHeader }

        switch toolKind {
        case .bash where has(["command"]):
            guard let command = string("command") else { break }
            return verdict(join(lines, keeping: { !excludedFromText($0, hasHeader: hasHeader) }), command, "the command")
        case .edit where has(["file_path", "old_string", "new_string"]):
            return checkFile(lines, fields: fields, pathKey: "file_path", known: ["file_path", "old_string", "new_string"]) {
                let old = verdict(join(lines, keeping: { $0 == .diffCtx || $0 == .diffDel }), string("old_string") ?? "", "the old text")
                if old != .verified { return old }
                return verdict(join(lines, keeping: { !excludedFromText($0, hasHeader: hasHeader) }), string("new_string") ?? "", "the new text")
            }
        case .write where has(["file_path", "content"]):
            return checkFile(lines, fields: fields, pathKey: "file_path", known: ["file_path", "content"]) {
                verdict(join(lines, keeping: { !excludedFromText($0, hasHeader: hasHeader) }), string("content") ?? "", "the content")
            }
        case .notebookEdit where has(["notebook_path"]):
            return checkFile(lines, fields: fields, pathKey: "notebook_path", known: ["notebook_path", "new_source"]) {
                verdict(join(lines, keeping: { !excludedFromText($0, hasHeader: hasHeader) }), string("new_source") ?? "", "the new source")
            }
        default:
            break
        }
        return checkJSON(lines, expected: input)
    }

    /// A file tool: the header is the path, `body` checks the text, and any other
    /// field of the input is shown as JSON lines that must be those fields.
    private static func checkFile(_ lines: [ApprovalRenderLine], fields: [String: ApprovalJSON]?,
                                  pathKey: String, known: [String],
                                  body: () -> ApprovalRoundTrip) -> ApprovalRoundTrip {
        guard case .string(let path)? = fields?[pathKey] else { return .mismatch("the path is missing") }
        let headers = lines.filter { $0.kind == .fileHeader }
        guard headers.count == 1, let header = headers.first,
              bytesEqual(header.runs.map(\.original).joined(), path)
        else { return .mismatch("the shown path is not the request's path") }
        let result = body()
        if result != .verified { return result }

        let extras = (fields ?? [:]).filter { !known.contains($0.key) }
        let jsonLines = lines.filter { $0.kind == .json }
        if extras.isEmpty {
            return jsonLines.isEmpty ? .verified : .mismatch("the display has fields the request does not")
        }
        return checkJSON(jsonLines, expected: .object(extras))
    }

    /// The `json` lines, joined, must parse to exactly the request's JSON.
    private static func checkJSON(_ lines: [ApprovalRenderLine], expected: ApprovalJSON) -> ApprovalRoundTrip {
        let json = lines.filter { $0.kind == .json || $0.kind == .unknown }
        guard json.count == lines.filter({ $0.kind != .fileHeader }).count else {
            return .mismatch("the display mixes JSON with other kinds of line")
        }
        let text = join(json, keeping: { _ in true })
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ApprovalJSON.self, from: data)
        else { return .mismatch("the shown JSON does not parse") }
        return parsed == expected ? .verified : .mismatch("the shown JSON differs from the request's input")
    }

    private static func excludedFromText(_ kind: ApprovalLineKind, hasHeader: Bool) -> Bool {
        kind == .fileHeader || kind == .diffDel || (hasHeader && kind == .json)
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
    var objectFields: [String: ApprovalJSON]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
