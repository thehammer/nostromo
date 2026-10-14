import Foundation
import NostromoKit

/// Hostile and oversized content that every transcript-fold slice reuses (design contract §4).
///
/// Nothing here is a fixture of "normal" data. It is what a tool call, a result, or an MCP
/// server name can contain when something upstream is broken or malicious.
enum HostileContent {

    // MARK: Single strings

    /// A 10,000-character single-line Bash command.
    static let longCommand: String = "echo " + String(repeating: "x", count: 9_995)

    /// ANSI colour escapes (CSI SGR).
    static let ansiColour = "\u{1B}[31mred text\u{1B}[0m and \u{1B}[1;32mgreen\u{1B}[0m"

    /// OSC 8 hyperlink, ST-terminated (`ESC \`).
    static let osc8Hyperlink = "\u{1B}]8;;https://x\u{1B}\\label\u{1B}]8;;\u{1B}\\"

    /// OSC 8 hyperlink, BEL-terminated.
    static let osc8HyperlinkBEL = "\u{1B}]8;;https://x\u{07}label\u{1B}]8;;\u{07}"

    /// Right-to-left override, isolates, and directional marks.
    static let bidi = "safe\u{202E}evil\u{2066}iso\u{2067}rtl\u{2068}fsi\u{2069}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}tail"

    /// Tag characters (invisible ASCII smuggling), including U+E0041.
    static let tagCharacters = "tag\u{E0041}\u{E0042}\u{E0043}\u{E007F}ged"

    /// NUL in the middle of a line.
    static let nul = "before\u{0}after"

    /// Every C1 control (U+0080 to U+009F), which includes the 8-bit CSI (U+009B).
    static let c1Controls: String = {
        let controls = (0x80 ... 0x9F).map { String(Unicode.Scalar($0)!) }.joined()
        return "a" + controls + "b \u{9B}31mred"
    }()

    /// Line breaks, tabs, carriage returns, DEL and other C0 controls.
    static let lineBreaksAndC0 = "one\ntwo\r\nthree\tfour\u{7F}five\u{8}six\u{B}seven\u{C}eight"

    /// One megabyte of multi-line text (a 1 MB tool result).
    static let megabyteResult: String = String(repeating: "0123456789abcde\n", count: 65_536)

    /// Everything at once, in one string.
    static let kitchenSink: String =
        ansiColour + osc8Hyperlink + osc8HyperlinkBEL + bidi + tagCharacters + nul + c1Controls + lineBreaksAndC0

    /// The hostile strings for the sanitizer sweep.
    static var all: [String] {
        [longCommand, ansiColour, osc8Hyperlink, osc8HyperlinkBEL, bidi, tagCharacters,
         nul, c1Controls, lineBreaksAndC0, megabyteResult, kitchenSink]
    }

    // MARK: Many things

    /// 60 distinct MCP tool names, one per server: `mcp__server<N>__tool`.
    static let mcpToolNames: [String] = (0 ..< 60).map { "mcp__server\($0)__tool" }

    /// 5,000 single-call groups in one turn: prose, call, result, repeated.
    /// Call ids are `hostile_<n>`.
    static func fiveThousandGroups() -> [FoldBlock] {
        var blocks: [FoldBlock] = []
        blocks.reserveCapacity(15_000)
        for n in 0 ..< 5_000 {
            blocks.append(.prose(nonEmpty: true))
            blocks.append(.toolCall(FoldCall(name: "Bash", toolUseId: "hostile_\(n)", inputSummary: "echo \(n)")))
            blocks.append(.toolResult(FoldResult(toolUseId: "hostile_\(n)")))
        }
        return blocks
    }

    // MARK: Predicates

    /// Scalars that must never survive onto a drawn row: C0 (incl. ESC, NL, CR, TAB), DEL, C1,
    /// bidi overrides/isolates/marks, and tag characters.
    static func isForbiddenOnARow(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000 ... 0x001F, 0x007F, 0x0080 ... 0x009F,
             0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069,
             0xE0000 ... 0xE007F:
            return true
        default:
            return false
        }
    }
}
