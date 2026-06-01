import Foundation

// MARK: - Turn (one user→assistant exchange)

/// One complete user→assistant exchange. Blocks accumulate live as Claude streams.
struct ChatTurn: Identifiable {
    let id         = UUID()
    let userInput:   String
    let timestamp:   Date
    var blocks:      [TurnBlock] = []
    var isComplete:  Bool        = false
    /// The daemon's stable turn id (monotonic per transcript), used to apply
    /// incremental `TurnDelta`s to the right turn. Nil for locally-built turns.
    var daemonId:    String?     = nil
}

// MARK: - Block types

enum TurnBlock {
    case text(String)
    case toolCall(ToolCallData)
    case toolResult(ToolResultData)
    case resultSummary(ResultSummaryData)
    case errorMessage(String)
    case askQuestion(AskQuestionData)
}

struct ToolCallData {
    let toolName:     String
    let inputSummary: String   // one-liner for the collapsed row
    let inputFull:    String   // pretty JSON for possible expansion
}

struct ToolResultData {
    let content: String
    let isError: Bool
}

struct ResultSummaryData {
    let durationMs: Int
    let costUSD:    Double
    let isError:    Bool
}

/// Structured question extracted from an `AskUserQuestion` tool_use block.
/// Rendered as a native card with tappable option buttons instead of a
/// generic tool-call row + error result.
struct AskQuestionData {
    struct Option {
        let label:       String
        let description: String
    }
    let question:    String
    let header:      String
    let options:     [Option]
    let multiSelect: Bool
}

// MARK: - NDJSON parsing

extension TurnBlock {

    enum ParseResult {
        case sessionId(String)
        case blocks([TurnBlock])
    }

    /// Parse one NDJSON line from `claude --output-format stream-json`.
    static func parse(line: String) -> ParseResult? {
        guard
            let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        switch json["type"] as? String ?? "" {

        case "system":
            guard let sid = json["session_id"] as? String else { return nil }
            return .sessionId(sid)

        case "assistant", "user":
            guard
                let msg     = json["message"] as? [String: Any],
                let content = msg["content"]  as? [[String: Any]]
            else { return nil }
            // expandConfirm splits any text block that contains a CONFIRM: line into
            // (optional leading text) + askQuestion card + (optional trailing text).
            let blocks = content.compactMap { parseContentBlock($0) }.flatMap { expandConfirm($0) }
            return blocks.isEmpty ? nil : .blocks(blocks)

        case "result":
            let dur     = json["duration_ms"] as? Int    ?? 0
            let cost    = json["total_cost_usd"] as? Double ?? 0
            let isError = json["is_error"]    as? Bool   ?? false
            return .blocks([.resultSummary(ResultSummaryData(
                durationMs: dur, costUSD: cost, isError: isError
            ))])

        default:
            return nil
        }
    }

    // MARK: Content block parsing

    private static func parseContentBlock(_ b: [String: Any]) -> TurnBlock? {
        switch b["type"] as? String ?? "" {

        case "text":
            let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : .text(t)

        case "tool_use":
            let name  = b["name"]  as? String        ?? "Tool"
            let input = b["input"] as? [String: Any] ?? [:]

            // AskUserQuestion: parse into a structured card instead of a generic tool row.
            // The claude CLI can't surface interactive UI in streaming mode, so we intercept
            // the input JSON and render it natively ourselves.
            if name == "AskUserQuestion", let card = parseAskQuestion(input) {
                return .askQuestion(card)
            }

            return .toolCall(ToolCallData(
                toolName:     name,
                inputSummary: summarize(name: name, input: input),
                inputFull:    prettyJSON(input)
            ))

        case "tool_result":
            let isError = b["is_error"] as? Bool ?? false
            var text    = ""
            if let s = b["content"] as? String {
                text = s
            } else if let arr = b["content"] as? [[String: Any]] {
                text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            // Suppress the "Answer questions?" error that AskUserQuestion always returns
            // in non-interactive (streaming) mode — it's noise; the card handles the UX.
            if isError && text.trimmingCharacters(in: .whitespaces) == "Answer questions?" {
                return nil
            }
            // Skip empty successful results — they're just ACKs
            guard !text.isEmpty || isError else { return nil }
            return .toolResult(ToolResultData(content: text, isError: isError))

        default:
            return nil
        }
    }

    /// Extract a structured `AskQuestionData` from an `AskUserQuestion` input dict.
    /// Returns nil if the input doesn't match the expected schema.
    private static func parseAskQuestion(_ input: [String: Any]) -> AskQuestionData? {
        guard
            let questions = input["questions"] as? [[String: Any]],
            let first     = questions.first,
            let question  = first["question"] as? String,
            !question.isEmpty
        else { return nil }

        let header      = first["header"]      as? String ?? ""
        let multiSelect = first["multiSelect"] as? Bool   ?? false
        let rawOptions  = first["options"]     as? [[String: Any]] ?? []
        let options: [AskQuestionData.Option] = rawOptions.compactMap { opt in
            guard let label = opt["label"] as? String, !label.isEmpty else { return nil }
            let desc = opt["description"] as? String ?? ""
            return AskQuestionData.Option(label: label, description: desc)
        }

        return AskQuestionData(
            question:    question,
            header:      header,
            options:     options,
            multiSelect: multiSelect
        )
    }

    // MARK: CONFIRM: line parsing

    /// If a text block contains one or more `CONFIRM:{json}` lines (emitted by the
    /// submit-review skill instead of the unsupported `AskUserQuestion` tool), split
    /// the block into: leading text • askQuestion card • trailing text.
    private static func expandConfirm(_ block: TurnBlock) -> [TurnBlock] {
        guard case .text(let t) = block else { return [block] }

        let lines   = t.components(separatedBy: "\n")
        var result: [TurnBlock] = []
        var pending: [String]   = []
        var didSplit             = false

        let backticks = CharacterSet(charactersIn: "`")
        for line in lines {
            // Tolerate agents wrapping the directive in markdown code
            // formatting — e.g. `CONFIRM:{…}` or ```CONFIRM:{…}``` — by stripping
            // surrounding backticks before matching. Without this the directive
            // renders as a raw code span instead of an interactive dialog.
            let trimmed = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: backticks)
                .trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("CONFIRM:") {
                // Flush any preceding text as its own block
                let pre = pending.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pre.isEmpty { result.append(.text(pre)) }
                pending = []

                // Parse the JSON that follows the prefix (strip any trailing
                // backticks/space that survived the unwrap).
                let jsonStr = String(trimmed.dropFirst("CONFIRM:".count))
                    .trimmingCharacters(in: backticks)
                    .trimmingCharacters(in: .whitespaces)
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let card = parseConfirmJSON(json) {
                    result.append(.askQuestion(card))
                    didSplit = true
                }
                // If JSON is malformed, the line is silently dropped (not shown to user)
            } else {
                pending.append(line)
            }
        }

        // Flush remaining text
        let tail = pending.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(.text(tail)) }

        // If nothing was split, return original block unchanged
        return didSplit ? result : [block]
    }

    /// Parse the compact JSON object emitted by the submit-review skill's CONFIRM: line.
    /// Keys: "q" (question), "h" (header), "opts" (array of {"l": label, "d": description}).
    private static func parseConfirmJSON(_ json: [String: Any]) -> AskQuestionData? {
        let question = json["q"] as? String ?? ""
        let header   = json["h"] as? String ?? ""
        let rawOpts  = json["opts"] as? [[String: Any]] ?? []
        let options: [AskQuestionData.Option] = rawOpts.compactMap { opt in
            guard let label = opt["l"] as? String, !label.isEmpty else { return nil }
            return AskQuestionData.Option(label: label, description: opt["d"] as? String ?? "")
        }
        guard !question.isEmpty || !options.isEmpty else { return nil }
        return AskQuestionData(question: question, header: header,
                               options: options, multiSelect: false)
    }

    // MARK: Input summarisation

    private static func summarize(name: String, input: [String: Any]) -> String {
        switch name {
        case "Read":
            return (input["file_path"] as? String).map { shortName($0) } ?? ""
        case "Write", "Edit", "MultiEdit":
            return (input["file_path"] as? String).map { shortName($0) } ?? ""
        case "Bash":
            return String((input["command"] as? String ?? "").prefix(80))
        case "Grep":
            return "pattern: \(input["pattern"] as? String ?? "")"
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "WebFetch":
            return input["url"] as? String ?? ""
        case "Agent":
            return (input["description"] as? String).map { String($0.prefix(60)) } ?? "subagent"
        case "TodoWrite":
            return "update todos"
        default:
            return input.values.compactMap { $0 as? String }.first.map { String($0.prefix(80)) } ?? ""
        }
    }

    private static func shortName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func prettyJSON(_ dict: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict,
                                                    options: [.prettyPrinted, .sortedKeys]),
            let str  = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}
