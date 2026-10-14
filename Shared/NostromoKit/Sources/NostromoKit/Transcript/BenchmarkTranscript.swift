import Foundation

/// Counts the generator derived from what it emitted. Tests re-derive the same
/// numbers by scanning the JSON, so a disagreement means one of the two is wrong.
public struct BenchmarkSummary: Equatable, Sendable {
    /// Turns in the session.
    public let turnCount: Int
    /// Top-level tool calls (calls carrying `parent_tool_use_id` are excluded).
    public let callCount: Int
    /// Group size → number of groups of that size.
    public let groupSizeHistogram: [Int: Int]
    /// Maximal runs of top-level calls; the sum of `groupSizeHistogram`'s counts.
    public let groupCount: Int
    /// Non-whitespace, top-level `text` blocks (blocks that end a group).
    public let proseBlockCount: Int
}

/// A deterministic benchmark session for the transcript tool-fold work.
///
/// The PRD's fixture is one session of 212 turns and 5,000+ tool calls. It is a
/// generator, not a committed multi-MB file: tests and the macOS load harness
/// (`NOSTROMO_LOAD_FIXTURE=benchmark`) both call it. Output is a JSON array of
/// daemon `Turn` objects in the wire shape of `src/ipc/stream_json.rs`
/// (`kind`-tagged blocks), plus the optional TF1 keys `tool_use_id`, `ts`,
/// `target` and `parent_tool_use_id`, which decoders that don't know them ignore.
///
/// Grouping rule used for `summary`: a group is a maximal run of top-level calls
/// (and their results). Non-empty prose, `ask_question`, `error_message` and
/// `result_summary` end it; whitespace-only prose and blocks with
/// `parent_tool_use_id` do not.
///
/// Shapes the wire cannot carry, and where they live instead:
/// - A turn whose calls are separated only by thinking is, on the wire, just
///   adjacent calls (thinking is never sent). The raw-stream version lives in
///   TF1's Rust fixture.
/// - Turns whose payload was dropped past the retention cap are a client-side
///   state, not a wire shape. TF2 simulates them through `TurnPayloadStore`.
public enum BenchmarkTranscript {

    /// Summary of the default seed with `emptyResults: false`. (The count shapes
    /// do not depend on `emptyResults`; other seeds draw different group sizes.)
    public static let summary: BenchmarkSummary =
        Generator.generate(seed: 1, emptyResults: false).summary

    /// The session as a JSON array of daemon turns.
    ///
    /// With `emptyResults: false`, empty successful results are omitted, as
    /// today's daemon does (`stream_json.rs:551`).
    public static func sessionTurnsJSON(seed: UInt64 = 1, emptyResults: Bool) -> Data {
        Generator.generate(seed: seed, emptyResults: emptyResults).json
    }

    /// The Focus view's scenario turns (PRD "Acceptance criteria" preamble) as a JSON array of
    /// daemon turns, in the same wire shape as `sessionTurnsJSON`: every `FocusScenario`,
    /// repeated until there are at least `focusScenarioMinTurns` turns. Turn ids are
    /// `f<n>-<scenario raw value>`. A separate generator (contract X2): `sessionTurnsJSON`
    /// stays byte-identical.
    public static func focusScenariosJSON(seed: UInt64 = 1) -> Data {
        Generator.generateFocus(seed: seed)
    }

    /// The fewest turns `focusScenariosJSON` emits.
    public static let focusScenarioMinTurns = 200
}

/// The turn shapes of the Focus fixture.
public enum FocusScenario: String, CaseIterable, Sendable {
    /// Tool groups only; the agent never speaks.
    case noMessages
    case oneMessage
    case twoMessages
    /// Ten messages interleaved with groups.
    case tenMessages
    /// A message, then tools, and no further message.
    case messageThenTools
    /// The turn ends on an unanswered ask card.
    case finalAskCard
    /// An ask card in the middle of the turn, with activity on both sides.
    case answeredAskMidTurn
    /// A model-change note in the middle of the turn.
    case midTurnNote
    case stopped
    case errored
    /// Every text block is whitespace-only.
    case whitespaceOnlyMessages
    /// Two text blocks with nothing between them (the wire never carries thinking).
    case thinkingBetweenMessages
    /// A 30 KB final message.
    case largeFinalMessage
    /// A markdown table in a message that folds.
    case markdownTable
    /// An image result inside activity.
    case imageResult

    /// The scenario a fixture turn id (`f<n>-<raw value>`) belongs to.
    public init?(turnId: String) {
        guard let dash = turnId.firstIndex(of: "-"), turnId.hasPrefix("f") else { return nil }
        self.init(rawValue: String(turnId[turnId.index(after: dash)...]))
    }
}

// MARK: - Random source

private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func range(_ r: ClosedRange<Int>) -> Int { r.lowerBound + below(r.count) }
}

// MARK: - Generator

private struct CallSpec {
    var name: String
    var summary: String
    var input: [String: Any]
    var target: String?
    /// A successful call whose result is empty (a quiet `mkdir`). The daemon
    /// drops these results; `emptyResults: true` emits them.
    var quiet = false
}

private struct Generator {
    typealias Block = [String: Any]

    static let regularTurns = 210
    static let minCalls = 5_300
    static let minGroups = 300
    static let mandatorySizes = [1, 2, 10, 60]
    static let mandatoryEach = 4
    /// Epoch seconds of 2026-01-01T00:00:00Z.
    static let baseEpoch: TimeInterval = 1_767_225_600

    var rng: SplitMix64
    let emptyResults: Bool
    let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var clockMs = 0
    var blocks: [Block] = []
    var nextId = 0
    var turnIndex = 0
    var runLength = 0

    var callCount = 0
    var proseCount = 0
    var histogram: [Int: Int] = [:]

    init(seed: UInt64, emptyResults: Bool) {
        rng = SplitMix64(seed: seed)
        self.emptyResults = emptyResults
    }

    // MARK: Plan

    /// Group sizes per regular turn, with the mandatory 1/2/10/60 groups mixed
    /// in and the remainder spread over 3–30.
    mutating func planGroups() -> [[Int]] {
        var sizes: [Int] = []
        for size in Self.mandatorySizes {
            sizes += Array(repeating: size, count: Self.mandatoryEach)
        }
        var total = sizes.reduce(0, +)
        while total < Self.minCalls || sizes.count < Self.minGroups {
            let size = rng.range(3...30)
            sizes.append(size)
            total += size
        }
        for i in stride(from: sizes.count - 1, to: 0, by: -1) {
            sizes.swapAt(i, rng.below(i + 1))
        }
        // Spread the extra groups evenly (Bresenham) instead of front-loading.
        let base = sizes.count / Self.regularTurns
        let extra = sizes.count % Self.regularTurns
        var plan: [[Int]] = []
        var cursor = 0
        for t in 0 ..< Self.regularTurns {
            let n = base + (((t + 1) * extra) / Self.regularTurns - (t * extra) / Self.regularTurns)
            plan.append(Array(sizes[cursor ..< cursor + n]))
            cursor += n
        }
        return plan
    }

    // MARK: Run

    static func generate(seed: UInt64, emptyResults: Bool) -> (json: Data, summary: BenchmarkSummary) {
        var generator = Generator(seed: seed, emptyResults: emptyResults)
        return generator.run()
    }

    mutating func run() -> (json: Data, summary: BenchmarkSummary) {
        let plan = planGroups()
        let errorTurn = (60 ..< Self.regularTurns).first { plan[$0].count >= 2 } ?? -1
        let whitespaceTurn = (20 ..< Self.regularTurns).first { (plan[$0].first ?? 0) >= 3 } ?? -1

        var turns: [Block] = []
        for t in 0 ..< Self.regularTurns {
            turns.append(regularTurn(t, groups: plan[t], errorTurn: errorTurn, whitespaceTurn: whitespaceTurn))
        }
        turns.append(stuckTurn(Self.regularTurns))
        turns.append(interruptedTurn(Self.regularTurns + 1))

        let json = try! JSONSerialization.data(withJSONObject: turns, options: [.sortedKeys, .withoutEscapingSlashes])
        let summary = BenchmarkSummary(
            turnCount: turns.count, callCount: callCount,
            groupSizeHistogram: histogram, groupCount: histogram.values.reduce(0, +),
            proseBlockCount: proseCount)
        return (json, summary)
    }

    // MARK: Turns

    mutating func beginTurn(_ t: Int) {
        turnIndex = t
        blocks = []
        nextId = 0
        runLength = 0
        clockMs += rng.range(2_000 ... 30_000)
    }

    mutating func finishTurn(_ t: Int, startMs: Int, isError: Bool, interrupted: Bool) -> Block {
        closeRun()
        blocks.append([
            "kind": "result_summary", "duration_ms": clockMs - startMs,
            "cost_usd": Double(rng.range(1 ... 400)) / 1000, "is_error": isError,
            "interrupted": interrupted, "ts": stamp(clockMs),
        ])
        return [
            "id": "t\(t)", "user_input": "Benchmark prompt \(t): \(sentence())",
            "timestamp": stamp(startMs), "blocks": blocks, "is_complete": true,
        ]
    }

    mutating func regularTurn(_ t: Int, groups: [Int], errorTurn: Int, whitespaceTurn: Int) -> Block {
        beginTurn(t)
        let startMs = clockMs
        prose("I'll start on step \(t): \(sentence())")
        for (g, size) in groups.enumerated() {
            if g > 0 { separator(turn: t, errorTurn: errorTurn) }
            emitGroup(size: size, group: g, whitespaceAfterFirst: t == whitespaceTurn && g == 0,
                      outcome: .normal)
        }
        prose("Done with step \(t). \(sentence())")
        return finishTurn(t, startMs: startMs, isError: false, interrupted: false)
    }

    /// The last group has a failure, and the turn ends in an error summary.
    mutating func stuckTurn(_ t: Int) -> Block {
        beginTurn(t)
        let startMs = clockMs
        prose("Trying the build again.")
        emitGroup(size: 5, group: 0, whitespaceAfterFirst: false, outcome: .stuck)
        return finishTurn(t, startMs: startMs, isError: true, interrupted: false)
    }

    /// The last call has no result, and the summary says the operator stopped it.
    mutating func interruptedTurn(_ t: Int) -> Block {
        beginTurn(t)
        let startMs = clockMs
        prose("Running the long job.")
        emitGroup(size: 4, group: 0, whitespaceAfterFirst: false, outcome: .interrupted)
        return finishTurn(t, startMs: startMs, isError: true, interrupted: true)
    }

    /// What goes between two groups of one turn: an ask card on some turns, one
    /// error message on one turn, otherwise agent prose.
    mutating func separator(turn t: Int, errorTurn: Int) {
        if t == errorTurn {
            closeRun()
            blocks.append(["kind": "error_message", "message": "Error: connection reset by peer", "ts": stamp(clockMs)])
        } else if t % 7 == 3 {
            closeRun()
            blocks.append([
                "kind": "ask_question", "question": "Which approach should I take for step \(t)?",
                "header": "Approach", "multi_select": false, "ts": stamp(clockMs),
                "options": [
                    ["label": "Keep going", "description": "Continue with the current plan.", "recommended": true],
                    ["label": "Stop here", "description": "Hold until you have looked.", "recommended": false],
                ],
            ])
        } else {
            prose("Next: \(sentence())")
        }
    }

    // MARK: Groups and calls

    enum Outcome { case normal, stuck, interrupted }

    mutating func emitGroup(size: Int, group g: Int, whitespaceAfterFirst: Bool, outcome: Outcome) {
        let t = turnIndex
        for idx in 0 ..< size {
            let isLast = idx == size - 1
            let isAgent = outcome == .normal && size >= 3 && idx == 1 && t % 9 == 4
            var spec = isAgent ? agentSpec() : pickTool()
            var dur = duration()
            var isError = rng.below(100) < 4
            var content = ""

            // Forced shapes. Each is keyed to (turn, group, idx) and the keys never collide.
            if size == 60 && idx == 1 { isError = true }
            if t == 40 && g == 0 && idx == 0 {
                spec = bash("cat build/big.log"); content = payload(bytes: 262_144)
            }
            if t == 90 && g == 0 && idx == 0 {
                spec = bash("cat build/huge.log"); content = payload(bytes: 1_048_576)
            }
            if t == 100 && g == 0 && idx == 0 { dur = 125_000 }
            if t == 50 && g == 0 && isLast {
                spec = CallSpec(name: "Read", summary: "screenshot.png",
                                input: ["file_path": "/tmp/screenshot.png"], target: "/tmp/screenshot.png",
                                quiet: true)
                isError = false
            }
            if outcome == .stuck && isLast { isError = true }
            if outcome == .interrupted && isLast { isError = false }
            if !content.isEmpty || spec.name == "Agent" { spec.quiet = false }
            if isError { spec.quiet = false }

            let id = call(spec, durationMs: dur)
            if isAgent { emitSubagent(parentId: id) }

            let interruptedLast = outcome == .interrupted && isLast
            if interruptedLast {
                clockMs += dur
            } else if spec.quiet && !emptyResults {
                clockMs += dur
            } else {
                if content.isEmpty && !spec.quiet {
                    content = isError ? "Error: exit status 1\n\(sentence())" : resultText(spec)
                }
                result(id: id, content: content, isError: isError, target: spec.target, durationMs: dur)
            }
            if whitespaceAfterFirst && idx == 0 {
                blocks.append(["kind": "text", "text": "  \n", "ts": stamp(clockMs)])
            }
        }
        closeRun()
    }

    /// Emits a `tool_call` and returns its id.
    mutating func call(_ spec: CallSpec, durationMs: Int) -> String {
        let id = newId()
        callTimes[id] = clockMs
        var block: Block = [
            "kind": "tool_call", "tool_name": spec.name, "input_summary": spec.summary,
            "input_full": pretty(spec.input), "tool_use_id": id, "ts": stamp(clockMs),
        ]
        if let target = spec.target { block["target"] = target }
        if let parent = currentParent { block["parent_tool_use_id"] = parent }
        else { callCount += 1; runLength += 1 }
        blocks.append(block)
        return id
    }

    /// Emits a `tool_result` whose `ts` is its call's start plus the duration.
    mutating func result(id: String, content: String, isError: Bool, target: String?, durationMs: Int) {
        // `max`: an Agent's own result lands after its subagent blocks.
        clockMs = max(clockMs, (callTimes[id] ?? clockMs) + durationMs)
        var block: Block = [
            "kind": "tool_result", "content": content, "is_error": isError,
            "tool_use_id": id, "ts": stamp(clockMs),
        ]
        if let target { block["target"] = target }
        if let parent = currentParent { block["parent_tool_use_id"] = parent }
        blocks.append(block)
        clockMs += rng.range(5 ... 400)
    }

    var callTimes: [String: Int] = [:]
    var currentParent: String?

    /// Three subagent calls with results and one subagent text, all tagged with
    /// the Agent call's id, before the Agent's own result.
    mutating func emitSubagent(parentId: String) {
        currentParent = parentId
        for i in 0 ..< 3 {
            let spec = i == 0 ? bash("rg -n TODO Sources") : CallSpec(
                name: "Read", summary: "Widget\(i).swift",
                input: ["file_path": "/repo/Sources/Widget\(i).swift"], target: "/repo/Sources/Widget\(i).swift")
            let dur = rng.range(50 ... 1_500)
            let id = call(spec, durationMs: dur)
            result(id: id, content: resultText(spec), isError: false, target: spec.target, durationMs: dur)
        }
        blocks.append(["kind": "text", "text": "Subagent: found three candidates.",
                       "parent_tool_use_id": parentId, "ts": stamp(clockMs)])
        currentParent = nil
    }

    // MARK: Block helpers

    mutating func prose(_ text: String) {
        closeRun()
        proseCount += 1
        blocks.append(["kind": "text", "text": text, "ts": stamp(clockMs)])
        clockMs += rng.range(200 ... 3_000)
    }

    mutating func closeRun() {
        if runLength > 0 { histogram[runLength, default: 0] += 1 }
        runLength = 0
    }

    mutating func newId() -> String {
        defer { nextId += 1 }
        return "toolu_bench_\(turnIndex)_\(nextId)"
    }

    func stamp(_ ms: Int) -> String {
        formatter.string(from: Date(timeIntervalSince1970: Self.baseEpoch + Double(ms) / 1000))
    }

    func pretty(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// 50 ms to 200 s, mostly short. Exactly one call is forced past 120 s (turn 100).
    mutating func duration() -> Int {
        let r = rng.below(1_000)
        switch r {
        case ..<700: return rng.range(50 ... 2_000)
        case ..<950: return rng.range(2_000 ... 20_000)
        case ..<999: return rng.range(20_000 ... 100_000)
        default: return rng.range(100_000 ... 110_000)   // capped well below 120 s
        }
    }

    // MARK: Content

    static let words = ["session", "transcript", "layout", "daemon", "turn", "block", "viewport",
                        "anchor", "group", "fold", "payload", "result", "stream", "pane"]
    static let files = ["Sources/App/ReplView.swift", "Sources/App/ChatSession.swift", "Sources/Kit/Wire.swift",
                        "src/ipc/stream_json.rs", "src/main.rs", "Package.swift", "README.md", "Makefile"]
    static let commands = ["swift test", "git status --short", "ls -la Sources", "rg -n fold Sources",
                           "make mac", "cargo test", "mkdir -p build/out", "cp a.txt build/out/",
                           "git add -A", "xcodebuild -scheme Nostromo build"]
    static let quietCommands: Set<String> = ["mkdir -p build/out", "cp a.txt build/out/", "git add -A"]

    mutating func sentence() -> String {
        (0 ..< rng.range(4 ... 10)).map { _ in Self.words[rng.below(Self.words.count)] }.joined(separator: " ") + "."
    }

    func payload(bytes: Int) -> String {
        let line = "benchmark payload line 0123456789 abcdefghijklmnopqrstuvwxyz\n"
        return String(String(repeating: line, count: bytes / line.utf8.count + 1).prefix(bytes))
    }

    func bash(_ command: String) -> CallSpec {
        CallSpec(name: "Bash", summary: command, input: ["command": command], target: command,
                 quiet: Self.quietCommands.contains(command))
    }

    func agentSpec() -> CallSpec {
        CallSpec(name: "Agent", summary: "Survey the call sites",
                 input: ["description": "Survey the call sites", "subagent_type": "Explore", "prompt": "Find usages."],
                 target: nil)
    }

    mutating func resultText(_ spec: CallSpec) -> String {
        switch spec.name {
        case "Edit", "Write": return "The file has been updated successfully."
        case "Agent": return "Found three candidates in Sources/."
        default: return (0 ..< rng.range(1 ... 6)).map { "line \($0): \(sentence())" }.joined(separator: "\n")
        }
    }

    /// Weighted pick over the tool mix, per mille.
    mutating func pickTool() -> CallSpec {
        let r = rng.below(1_000)
        let file = Self.files[rng.below(Self.files.count)]
        let base = (file as NSString).lastPathComponent
        switch r {
        case ..<300: return bash(Self.commands[rng.below(Self.commands.count)])
        case ..<520: return CallSpec(name: "Read", summary: base, input: ["file_path": "/repo/\(file)"], target: "/repo/\(file)")
        case ..<620: return CallSpec(name: "Edit", summary: base,
                                     input: ["file_path": "/repo/\(file)", "old_string": "foo", "new_string": "bar"],
                                     target: "/repo/\(file)")
        case ..<660: return CallSpec(name: "Write", summary: base,
                                     input: ["file_path": "/repo/\(file)", "content": "// generated\n"], target: "/repo/\(file)")
        case ..<750: return CallSpec(name: "Grep", summary: "fold", input: ["pattern": "fold", "path": "Sources"], target: "fold")
        case ..<790: return CallSpec(name: "Glob", summary: "**/*.swift", input: ["pattern": "**/*.swift"], target: "**/*.swift")
        case ..<820: return CallSpec(name: "WebFetch", summary: "https://example.com/docs",
                                     input: ["url": "https://example.com/docs", "prompt": "Summarize"], target: "https://example.com/docs")
        case ..<850: return CallSpec(name: "TodoWrite", summary: "2 todos",
                                     input: ["todos": [["content": "Write tests", "status": "in_progress"],
                                                       ["content": "Ship it", "status": "pending"]]], target: nil)
        case ..<910:
            let name = ["mcp__nostromo__list_agents", "mcp__nostromo__send_message"][rng.below(2)]
            return CallSpec(name: name, summary: name, input: ["tag": "agent-\(rng.below(8))"], target: nil)
        case ..<994:
            let name = ["mcp__claude_ai_Atlassian__getJiraIssue", "mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql"][rng.below(2)]
            return CallSpec(name: name, summary: name, input: ["issueIdOrKey": "CORE-\(rng.range(100 ... 999))"], target: nil)
        default: return CallSpec(name: "FrobnicateWidget", summary: "widget \(rng.below(100))",
                                 input: ["widget": rng.below(100)], target: nil)
        }
    }
}

// MARK: - Focus scenarios

/// The Focus fixture (contract X2). It only adds to `Generator`; nothing the benchmark session
/// uses is changed, so `sessionTurnsJSON` stays byte-identical. Turn numbers start at 1,000 so
/// none of the benchmark's turn-keyed shapes (turns 40, 50, 90, 100) apply.
extension Generator {

    static func generateFocus(seed: UInt64) -> Data {
        var generator = Generator(seed: seed, emptyResults: false)
        return generator.runFocus()
    }

    mutating func runFocus() -> Data {
        var turns: [Block] = []
        while turns.count < BenchmarkTranscript.focusScenarioMinTurns {
            for scenario in FocusScenario.allCases {
                turns.append(focusTurn(scenario, number: turns.count))
            }
        }
        return try! JSONSerialization.data(withJSONObject: turns, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    mutating func focusTurn(_ scenario: FocusScenario, number n: Int) -> Block {
        beginTurn(1_000 + n)
        let startMs = clockMs
        let id = "f\(n)-\(scenario.rawValue)"
        var summary: (isError: Bool, interrupted: Bool)? = (false, false)

        switch scenario {
        case .noMessages:
            emitGroup(size: 4, group: 0, whitespaceAfterFirst: false, outcome: .normal)
        case .oneMessage:
            prose("Nothing to change here: \(sentence())")
        case .twoMessages:
            prose("Looking at the layout first. \(sentence())")
            emitGroup(size: 4, group: 0, whitespaceAfterFirst: false, outcome: .normal)
            prose("All checked. \(sentence())")
        case .tenMessages:
            for i in 0 ..< 10 {
                prose("Step \(i): \(sentence())")
                if i < 9 { emitGroup(size: 2 + i % 4, group: i, whitespaceAfterFirst: false, outcome: .normal) }
            }
        case .messageThenTools:
            prose("Running the checks now. \(sentence())")
            emitGroup(size: 3, group: 0, whitespaceAfterFirst: false, outcome: .normal)
        case .finalAskCard:
            prose("Let me look at the options. \(sentence())")
            emitGroup(size: 3, group: 0, whitespaceAfterFirst: false, outcome: .normal)
            prose("I found two ways to do this and need a decision. \(sentence())")
            askCard()
            summary = nil
        case .answeredAskMidTurn:
            prose("Before I go on I need a decision. \(sentence())")
            emitGroup(size: 3, group: 0, whitespaceAfterFirst: false, outcome: .normal)
            askCard()
            emitGroup(size: 2, group: 1, whitespaceAfterFirst: false, outcome: .normal)
            prose("Done with the chosen approach. \(sentence())")
        case .midTurnNote:
            prose("Starting on the first part. \(sentence())")
            emitGroup(size: 3, group: 0, whitespaceAfterFirst: false, outcome: .normal)
            closeRun()
            blocks.append(["kind": "note", "note_kind": "model_changed",
                           "text": "Model changed to Opus (from Sonnet) by you.", "ts": stamp(clockMs)])
            emitGroup(size: 2, group: 1, whitespaceAfterFirst: false, outcome: .normal)
            prose("Finished the second part. \(sentence())")
        case .stopped:
            prose("Running the long job. \(sentence())")
            emitGroup(size: 4, group: 0, whitespaceAfterFirst: false, outcome: .interrupted)
            summary = (true, true)
        case .errored:
            prose("Trying the build again. \(sentence())")
            emitGroup(size: 5, group: 0, whitespaceAfterFirst: false, outcome: .stuck)
            blocks.append(["kind": "error_message", "message": "Error: connection reset by peer", "ts": stamp(clockMs)])
            summary = (true, false)
        case .whitespaceOnlyMessages:
            whitespace()
            emitGroup(size: 3, group: 0, whitespaceAfterFirst: true, outcome: .normal)
            whitespace()
        case .thinkingBetweenMessages:
            prose("First thought. \(sentence())")
            prose("Second thought, nothing between. \(sentence())")
            emitGroup(size: 3, group: 0, whitespaceAfterFirst: false, outcome: .normal)
            prose("Conclusion, part one. \(sentence())")
            prose("Conclusion, part two. \(sentence())")
        case .largeFinalMessage:
            prose("Collecting the results. \(sentence())")
            emitGroup(size: 3, group: 0, whitespaceAfterFirst: false, outcome: .normal)
            prose(String(String(repeating: "A long closing paragraph about the layout. ", count: 800).prefix(30_000)))
        case .markdownTable:
            prose("Here is the comparison:\n\n| Option | Cost |\n|---|---|\n| A | 1 |\n| B | 2 |\n")
            emitGroup(size: 3, group: 0, whitespaceAfterFirst: false, outcome: .normal)
            prose("Option A is cheaper. \(sentence())")
        case .imageResult:
            prose("Taking a screenshot of the result. \(sentence())")
            imageGroup()
            prose("The screenshot looks right. \(sentence())")
        }

        closeRun()
        if let summary {
            blocks.append([
                "kind": "result_summary", "duration_ms": clockMs - startMs,
                "cost_usd": Double(rng.range(1 ... 400)) / 1000, "is_error": summary.isError,
                "interrupted": summary.interrupted, "ts": stamp(clockMs),
            ])
        }
        return [
            "id": id, "user_input": "Focus scenario \(n): \(sentence())",
            "timestamp": stamp(startMs), "blocks": blocks, "is_complete": summary != nil,
        ]
    }

    mutating func askCard() {
        closeRun()
        blocks.append([
            "kind": "ask_question", "question": "Which approach should I take?",
            "header": "Approach", "multi_select": false, "ts": stamp(clockMs),
            "options": [
                ["label": "Keep going", "description": "Continue with the current plan.", "recommended": true],
                ["label": "Stop here", "description": "Hold until you have looked.", "recommended": false],
            ],
        ])
    }

    mutating func whitespace() {
        closeRun()
        blocks.append(["kind": "text", "text": "  \n", "ts": stamp(clockMs)])
    }

    /// A group of two calls whose second is a `Read` of an image.
    mutating func imageGroup() {
        let build = bash("swift build")
        let buildId = call(build, durationMs: 800)
        result(id: buildId, content: resultText(build), isError: false, target: build.target, durationMs: 800)
        let read = CallSpec(name: "Read", summary: "screenshot.png", input: ["file_path": "/tmp/screenshot.png"],
                            target: "/tmp/screenshot.png")
        let readId = call(read, durationMs: 400)
        result(id: readId, content: "[Image: screenshot.png, 1280x800 PNG]", isError: false,
               target: read.target, durationMs: 400)
        closeRun()
    }
}
