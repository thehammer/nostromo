import Foundation

// MARK: - Turn (one user→assistant exchange)

/// One complete user→assistant exchange. Blocks accumulate live as Claude streams.
///
/// Two distinct notions of identity live on this type, and conflating them is
/// what produced the reconnect duplication bug (see `TurnReconciler`):
///
///   - `id` is **view identity**. Assigned once, when the client first sees a
///     turn, and carried forward across every reattach. `ReplView` keys its
///     materialized views by it.
///   - `(epoch, daemonId)` is the turn's **current wire address**, rewritten on
///     every reattach. The daemon re-numbers turns from `t0` each time its
///     `SessionTranscript` is rebuilt, so a bare `daemonId` is ambiguous across
///     daemon restarts.
struct ChatTurn: Identifiable {
    /// Reassigned only by `carryingIdentity(of:)`, on the reconcile path.
    private(set) var id: UUID
    /// The user's message. Mutable because `TurnPayloadStore` swaps the full
    /// text for a bounded prefix when the turn goes cold.
    var userInput:   String
    var timestamp:   Date
    /// The daemon's raw ISO-8601 timestamp string, exactly as it appeared in the
    /// record. `timestamp` is lossy for identity purposes — a turn with no
    /// timestamp in the stream decodes to `Date()`, which differs on every
    /// reattach — so cross-epoch matching uses this instead.
    var timestampRaw: String?  = nil
    var blocks:      [TurnBlock] = []
    var isComplete:  Bool        = false
    /// The daemon's turn id **within the current epoch**, used to apply
    /// incremental `TurnDelta`s to the right turn. Nil for locally-built turns
    /// (optimistic echoes) until the matching `turnStarted` delta adopts them.
    var daemonId:    String?     = nil
    /// Which daemon-side transcript lifetime `daemonId` belongs to. Incremented
    /// by `ChatSession` on every attach snapshot. Delta lookups filter on the
    /// current epoch so a re-issued `t30` can never land on an ancient turn.
    var epoch:       Int         = 0
    /// Non-nil for the synthetic turns that keep the transcript honest about
    /// history it cannot show. These carry no daemon address and never match
    /// during reconciliation.
    var marker:      Marker?     = nil
    /// Original content lengths, retained when `TurnPayloadStore` truncated this
    /// turn's text into a skeleton. Nil while the turn holds its full payload.
    ///
    /// Without this a cold turn would estimate its height from the 512-character
    /// prefix that survived truncation, and a 40 KB turn would claim to be three
    /// lines tall — collapsing the document and destroying the scroll position.
    var truncatedLengths: TruncatedLengths? = nil

    /// Character counts for a turn whose text has been compressed away.
    struct TruncatedLengths {
        let userInput: Int
        /// Parallel to `ChatTurn.blocks`.
        let blocks: [Int]
    }

    /// A synthetic, operator-visible statement about missing history.
    enum Marker: Equatable {
        /// The client was away for longer than the daemon's attach window, so
        /// turns between the retained history and the snapshot are missing.
        case gap
        /// Retention hit `TurnPayloadStore.maxRetainedTurns` and the oldest
        /// turns were dropped. Pinned at the top of the transcript.
        case historyUnavailable
    }

    var isGapMarker: Bool { marker == .gap }

    init(id: UUID = UUID(),
         userInput: String,
         timestamp: Date,
         timestampRaw: String? = nil,
         blocks: [TurnBlock] = [],
         isComplete: Bool = false,
         daemonId: String? = nil,
         epoch: Int = 0,
         marker: Marker? = nil) {
        self.id           = id
        self.userInput    = userInput
        self.timestamp    = timestamp
        self.timestampRaw = timestampRaw
        self.blocks       = blocks
        self.isComplete   = isComplete
        self.daemonId     = daemonId
        self.epoch        = epoch
        self.marker       = marker
    }

    /// A marker turn, rendered as a plain statement rather than a chat exchange.
    static func marker(_ kind: Marker, timestamp: Date = Date()) -> ChatTurn {
        ChatTurn(userInput: "", timestamp: timestamp, isComplete: true, marker: kind)
    }

    /// This turn, wearing `other`'s view identity.
    ///
    /// The reconciler's whole job in one method: an attach snapshot carries the
    /// current wire address for a turn we already have, and the turn's *view*
    /// identity must survive that. `id` is otherwise immutable — reassigning it
    /// anywhere else would orphan a materialized view.
    func carryingIdentity(of other: ChatTurn) -> ChatTurn {
        var out = self
        out.id = other.id
        return out
    }
}

// MARK: - Cross-epoch identity

extension ChatTurn {

    /// Identity of the underlying record entry, independent of which daemon
    /// epoch delivered it.
    ///
    /// The daemon's own turn ids restart at `t0` on every restart
    /// (`stream_json.rs` `alloc_id`), so they cannot anchor identity. What *is*
    /// stable is the pair (record timestamp, user text): both come from the same
    /// JSONL line whether the daemon parsed it live or re-read it from disk.
    var identityKey: String {
        "\(timestampRaw ?? "-")|\(userInput.prefix(256))"
    }

    /// `identityKey` plus the turn's durable block shape.
    ///
    /// Used as the height-cache key in `TurnListVirtualizer` (rendered height is
    /// a function of block shape) — **not** as the reconciliation match key. See
    /// `TurnReconciler.matches` for why block shape can legitimately differ
    /// between two views of the same turn.
    var contentKey: String {
        let durable = blocks.filter { $0.isDurable }
        return "\(identityKey)|\(durable.count)|\(durable.map { $0.kindCode }.joined())"
    }

    /// Character count of the user's message before any truncation.
    var userInputLength: Int {
        truncatedLengths?.userInput ?? userInput.count
    }

    /// Character count of the block at `index` before any truncation.
    func contentLength(ofBlockAt index: Int) -> Int {
        if let lengths = truncatedLengths, index < lengths.blocks.count {
            return lengths.blocks[index]
        }
        guard index < blocks.count else { return 0 }
        return blocks[index].contentCharCount
    }
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

extension TurnBlock {

    /// Single-character code for this block's kind, used to build
    /// `ChatTurn.contentKey` and to key height estimation.
    var kindCode: String {
        switch self {
        case .text:          return "t"
        case .toolCall:      return "c"
        case .toolResult:    return "r"
        case .resultSummary: return "s"
        case .errorMessage:  return "e"
        case .askQuestion:   return "q"
        }
    }

    /// False for blocks the daemon synthesises from the *live* stream but cannot
    /// reproduce when it re-reads the record from disk.
    ///
    /// `resultSummary` comes from a `result` line, and `errorMessage` from an
    /// unexpected child exit; neither appears in the stored session JSONL
    /// (`stream_json.rs` notes "stored JSONL has no `result` lines"). So the same
    /// turn has one block shape when watched live and another after a daemon
    /// restart re-parses it. Excluding them keeps `contentKey` stable across
    /// that boundary.
    var isDurable: Bool {
        switch self {
        case .resultSummary, .errorMessage: return false
        default:                            return true
        }
    }

    /// Character count of the text this block renders. Drives height estimation.
    var contentCharCount: Int {
        switch self {
        case .text(let s):          return s.count
        case .toolCall(let d):      return d.inputSummary.count
        case .toolResult(let d):    return d.content.count
        case .resultSummary:        return 0
        case .errorMessage(let m):  return m.count
        case .askQuestion(let d):   return d.question.count
        }
    }

    /// Rough uncompressed size of this block's payload, in bytes. Used by
    /// `TranscriptDiagnostics`.
    var payloadByteCount: Int {
        switch self {
        case .text(let s):          return s.utf8.count
        case .toolCall(let d):      return d.inputSummary.utf8.count + d.inputFull.utf8.count
        case .toolResult(let d):    return d.content.utf8.count
        case .resultSummary:        return 0
        case .errorMessage(let m):  return m.utf8.count
        case .askQuestion(let d):
            return d.question.utf8.count + d.header.utf8.count
                + d.options.reduce(0) { $0 + $1.label.utf8.count + $1.description.utf8.count }
        }
    }
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
        /// True when this is Perri's (or the agent's) recommended choice.
        /// Rendered as a "(recommended)" suffix on the option label.
        let recommended: Bool

        init(label: String, description: String, recommended: Bool = false) {
            self.label       = label
            self.description = description
            self.recommended = recommended
        }
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

        // Note: sidechain filtering (isSidechain:true user events from sub-agent
        // prompts) is handled in the Rust daemon parser (parse_user_event). String-
        // content user events already yield nil here (content is not [[String:Any]]),
        // so no additional guard is needed in this path.
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
    /// Keys: "q" (question), "h" (header), "opts" (array of {"l": label, "d": description,
    /// "r": recommended — optional bool marking Perri's recommended option}).
    private static func parseConfirmJSON(_ json: [String: Any]) -> AskQuestionData? {
        let question = json["q"] as? String ?? ""
        let header   = json["h"] as? String ?? ""
        let rawOpts  = json["opts"] as? [[String: Any]] ?? []
        let options: [AskQuestionData.Option] = rawOpts.compactMap { opt in
            guard let label = opt["l"] as? String, !label.isEmpty else { return nil }
            return AskQuestionData.Option(
                label:       label,
                description: opt["d"] as? String ?? "",
                recommended: opt["r"] as? Bool ?? false)
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
