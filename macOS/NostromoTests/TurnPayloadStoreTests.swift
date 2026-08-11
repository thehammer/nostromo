import XCTest
// ChatTurn, TurnBlock and TurnPayloadStore are compiled into this target
// directly (logic test — no host app). No module imports needed.

// MARK: - TurnPayloadStoreTests

/// Behavioural tests for `TurnPayloadStore`.
///
/// Two contracts are under test and they pull in opposite directions:
///
///  1. **Bounded memory.** Retaining a long session must cost a slope, not an
///     unbounded heap. The criterion is ≤ 20 MB per 1,000 turns, and
///     `testRetainedBytesPerThousandTurnsStaysUnderTheBudget` measures it
///     against a synthetic corpus rather than asserting anything about the
///     encoding.
///  2. **Honesty.** Whatever the store does to save space, expanding a turn must
///     never silently produce empty content. Either the full text comes back, or
///     the caller is told it cannot.
///
/// Nothing here inspects `blobs`, `pinned` or `dropped`. Compaction is observed
/// through the skeleton handed back to the completion, through `hydrate`, and
/// through `stats`.
final class TurnPayloadStoreTests: XCTestCase {

    // MARK: - Fixtures

    private static let baseDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeTurn(seq: Int = 0,
                          user: String = "hello",
                          blocks: [TurnBlock] = [],
                          complete: Bool = true) -> ChatTurn {
        ChatTurn(userInput:    user,
                 timestamp:    Self.baseDate.addingTimeInterval(Double(seq)),
                 timestampRaw: String(format: "2026-08-11T12:00:00.%04dZ", seq),
                 blocks:       blocks,
                 isComplete:   complete,
                 daemonId:     "t\(seq)",
                 epoch:        0)
    }

    private func ascii(_ n: Int) -> String { String(repeating: "a", count: n) }

    /// Text that a naive character-count encoding would mangle: a multi-scalar
    /// grapheme cluster, CJK, and combining marks all have a UTF-8 byte count
    /// wildly different from their `String.count`.
    private static let unicodeSample = "👨‍👩‍👧‍👦 家族 — こんにちは, ǹ̸̡͇o̶̢͐ísy̷̙͝ 🚀🇯🇵 «déjà vu» ✅"

    /// Wait for the store to finish one compaction. `compact` compresses off the
    /// main thread and calls back on main, so the run loop has to turn.
    @discardableResult
    private func compactAndWait(_ store: TurnPayloadStore, _ turn: ChatTurn,
                                timeout: TimeInterval = 10,
                                file: StaticString = #filePath,
                                line: UInt = #line) -> ChatTurn? {
        let done = expectation(description: "compacted")
        var skeleton: ChatTurn?
        store.compact(turn) { result in
            skeleton = result
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        if skeleton == nil {
            XCTFail("compaction never completed", file: file, line: line)
        }
        return skeleton
    }

    private func assertFull(_ hydration: TurnPayloadStore.Hydration,
                            _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) -> ChatTurn? {
        switch hydration {
        case .full(let turn):
            return turn
        case .unavailable:
            XCTFail("\(message) expected full content, got .unavailable", file: file, line: line)
            return nil
        }
    }

    // MARK: - 1. Round trip

    func testPayloadRoundTripsThroughCompressionByteForByte() throws {
        let userInput   = Self.unicodeSample + " " + ascii(3_000)
        let prose       = "## Heading\n\n" + Self.unicodeSample + "\n\n" + ascii(9_000)
        let inputFull   = "{\n  \"pattern\": \"\(Self.unicodeSample)\",\n  \"path\": \"\(ascii(2_000))\"\n}"
        let toolContent = String(repeating: Self.unicodeSample + " diff line\n",
                                 count: 256 * 1_024 / 64) + ascii(4_096)

        XCTAssertGreaterThan(toolContent.utf8.count, 256 * 1_024,
                             "fixture must actually be a 256 KB result")

        let turn = makeTurn(user: userInput, blocks: [
            .text(prose),
            .toolCall(ToolCallData(toolName: "Grep", inputSummary: "pattern: x", inputFull: inputFull)),
            .toolResult(ToolResultData(content: toolContent, isError: false)),
            .resultSummary(ResultSummaryData(durationMs: 12, costUSD: 0.4, isError: false)),
        ])

        let payload = try XCTUnwrap(TurnPayloadStore.encodePayload(turn))
        let compressed = try XCTUnwrap((payload as NSData).compressed(using: .lzfse) as Data?)
        let decompressed = try XCTUnwrap((compressed as NSData).decompressed(using: .lzfse) as Data?)
        XCTAssertEqual(decompressed, payload, "compression must be lossless")

        // Decode into the skeleton, which is what the app actually holds by the
        // time anyone asks for the payload back.
        let skeleton = TurnPayloadStore.skeleton(of: turn)
        let restored = try XCTUnwrap(TurnPayloadStore.decodePayload(decompressed, into: skeleton))

        XCTAssertEqual(restored.userInput, userInput)
        XCTAssertEqual(restored.blocks.count, turn.blocks.count)
        guard restored.blocks.count == 4 else { return }

        guard case .text(let restoredProse) = restored.blocks[0] else {
            return XCTFail("block 0 must still be text")
        }
        XCTAssertEqual(restoredProse, prose)

        guard case .toolCall(let call) = restored.blocks[1] else {
            return XCTFail("block 1 must still be a tool call")
        }
        XCTAssertEqual(call.inputFull, inputFull)
        XCTAssertEqual(call.toolName, "Grep")
        XCTAssertEqual(call.inputSummary, "pattern: x")

        guard case .toolResult(let result) = restored.blocks[2] else {
            return XCTFail("block 2 must still be a tool result")
        }
        XCTAssertEqual(result.content, toolContent)
        XCTAssertEqual(result.content.utf8.count, toolContent.utf8.count)
        XCTAssertFalse(result.isError)
    }

    func testUnicodeSurvivesWhereACharacterCountEncodingWouldNot() throws {
        // Guards the specific trap: `String.count` for this text is far smaller
        // than its UTF-8 length, so a length prefix measured in characters would
        // slice mid-scalar and corrupt every field after it.
        let text = String(repeating: Self.unicodeSample, count: 200)
        XCTAssertNotEqual(text.count, text.utf8.count, "fixture must be multi-byte")

        let turn = makeTurn(user: text, blocks: [.text(text), .text("ascii tail")])
        let payload = try XCTUnwrap(TurnPayloadStore.encodePayload(turn))
        let restored = try XCTUnwrap(TurnPayloadStore.decodePayload(payload, into: turn))

        XCTAssertEqual(restored.userInput, text)
        guard restored.blocks.count == 2 else { return XCTFail("block shape must survive") }
        guard case .text(let a) = restored.blocks[0], case .text(let b) = restored.blocks[1] else {
            return XCTFail("blocks must still be text")
        }
        XCTAssertEqual(a, text)
        XCTAssertEqual(b, "ascii tail", "a mis-sized prefix would corrupt everything after it")
    }

    func testAnEmptyTurnRoundTrips() throws {
        let turn = makeTurn(user: "", blocks: [])
        let payload = try XCTUnwrap(TurnPayloadStore.encodePayload(turn))
        let restored = try XCTUnwrap(TurnPayloadStore.decodePayload(payload, into: turn))
        XCTAssertEqual(restored.userInput, "")
        XCTAssertTrue(restored.blocks.isEmpty)
    }

    // MARK: - 2. What the skeleton keeps

    func testSkeletonKeepsWhatTheCollapsedUINeeds() {
        let summary = "rg --hidden --glob '!node_modules' " + ascii(400)
        let turn = makeTurn(user: ascii(2_000), blocks: [
            .text(ascii(5_000)),
            .toolCall(ToolCallData(toolName: "Bash", inputSummary: summary, inputFull: ascii(30_000))),
            .toolResult(ToolResultData(content: ascii(300_000), isError: false)),
            .toolResult(ToolResultData(content: ascii(9_000), isError: true)),
            .resultSummary(ResultSummaryData(durationMs: 4_321, costUSD: 0.75, isError: true)),
            .errorMessage("child exited with status 137"),
            .askQuestion(AskQuestionData(question: "Ship it?", header: "Decision",
                                         options: [.init(label: "Yes", description: "merge"),
                                                   .init(label: "No", description: "hold")],
                                         multiSelect: false)),
        ])

        let skeleton = TurnPayloadStore.skeleton(of: turn)

        XCTAssertEqual(skeleton.id, turn.id, "compaction must not change view identity")
        XCTAssertEqual(skeleton.blocks.count, turn.blocks.count,
                       "the collapsed transcript still renders one row per block")
        guard skeleton.blocks.count == 7 else { return }

        // Bounded text prefixes, with real words in them.
        XCTAssertEqual(skeleton.userInput.count, TurnPayloadStore.prefixLength)
        XCTAssertTrue(turn.userInput.hasPrefix(skeleton.userInput))
        guard case .text(let prose) = skeleton.blocks[0] else { return XCTFail("block 0") }
        XCTAssertEqual(prose.count, TurnPayloadStore.prefixLength)

        // Tool call: name and a bounded one-line summary survive; the bulky
        // pretty-printed input does not.
        guard case .toolCall(let call) = skeleton.blocks[1] else { return XCTFail("block 1") }
        XCTAssertEqual(call.toolName, "Bash")
        XCTAssertTrue(summary.hasPrefix(call.inputSummary))
        XCTAssertLessThanOrEqual(call.inputSummary.count, 120,
                                 "the collapsed row is one line; keeping more is dead weight")
        XCTAssertGreaterThan(call.inputSummary.count, 0,
                             "the collapsed row would be blank without a summary")
        XCTAssertLessThan(call.inputFull.utf8.count, summary.utf8.count,
                          "the expandable JSON is the bulk and must not be retained")

        // Tool results: bounded prefix, and the error flag — which decides
        // whether the row renders open — must survive.
        guard case .toolResult(let ok) = skeleton.blocks[2],
              case .toolResult(let bad) = skeleton.blocks[3] else { return XCTFail("blocks 2-3") }
        XCTAssertEqual(ok.content.count, TurnPayloadStore.prefixLength)
        XCTAssertFalse(ok.isError)
        XCTAssertTrue(bad.isError, "an error result loses its whole meaning without this flag")

        // Small structured blocks are cheap and are kept whole.
        guard case .resultSummary(let stats) = skeleton.blocks[4] else { return XCTFail("block 4") }
        XCTAssertEqual(stats.durationMs, 4_321)
        XCTAssertEqual(stats.costUSD, 0.75, accuracy: 0.0001)
        XCTAssertTrue(stats.isError)

        guard case .errorMessage(let message) = skeleton.blocks[5] else { return XCTFail("block 5") }
        XCTAssertEqual(message, "child exited with status 137")

        guard case .askQuestion(let card) = skeleton.blocks[6] else { return XCTFail("block 6") }
        XCTAssertEqual(card.question, "Ship it?")
        XCTAssertEqual(card.header, "Decision")
        XCTAssertEqual(card.options.map(\.label), ["Yes", "No"],
                       "an unanswered question card must stay answerable")
    }

    func testSkeletonOfAShortTurnKeepsItWhole() {
        let turn = makeTurn(user: "hi", blocks: [.text("done"),
                                                 .toolResult(ToolResultData(content: "ok", isError: false))])
        let skeleton = TurnPayloadStore.skeleton(of: turn)

        XCTAssertEqual(skeleton.userInput, "hi")
        guard skeleton.blocks.count == 2 else { return XCTFail("block shape must survive") }
        guard case .text(let s) = skeleton.blocks[0] else { return XCTFail("block 0") }
        XCTAssertEqual(s, "done")
    }

    func testSkeletonIsSubstantiallySmallerThanTheTurnItReplaces() {
        let turn = makeTurn(user: ascii(20_000), blocks: [
            .text(ascii(40_000)),
            .toolCall(ToolCallData(toolName: "Read", inputSummary: "x.swift", inputFull: ascii(50_000))),
            .toolResult(ToolResultData(content: ascii(300_000), isError: false)),
        ])
        let before = turn.userInput.utf8.count + turn.blocks.reduce(0) { $0 + $1.payloadByteCount }
        let skeleton = TurnPayloadStore.skeleton(of: turn)
        let after = skeleton.userInput.utf8.count + skeleton.blocks.reduce(0) { $0 + $1.payloadByteCount }

        XCTAssertLessThan(after, before / 100,
                          "compaction that does not shrink the turn is pointless")
    }

    // MARK: - 3. Recorded original lengths

    func testSkeletonRecordsTheOriginalContentLengths() throws {
        let summary = ascii(400)
        let turn = makeTurn(user: ascii(2_000), blocks: [
            .text(ascii(5_000)),
            .toolCall(ToolCallData(toolName: "Bash", inputSummary: summary, inputFull: ascii(30_000))),
            .toolResult(ToolResultData(content: ascii(300_000), isError: false)),
            .resultSummary(ResultSummaryData(durationMs: 1, costUSD: 0, isError: false)),
        ])

        let skeleton = TurnPayloadStore.skeleton(of: turn)
        let lengths = try XCTUnwrap(skeleton.truncatedLengths)

        XCTAssertEqual(lengths.userInput, 2_000)
        XCTAssertEqual(lengths.blocks, [5_000, 400, 300_000, 0],
                       "the recorded lengths must describe the original, not the survivor")

        // And the accessors the height estimator uses must report the original.
        XCTAssertEqual(skeleton.userInputLength, 2_000)
        XCTAssertEqual(skeleton.contentLength(ofBlockAt: 0), 5_000)
        XCTAssertEqual(skeleton.contentLength(ofBlockAt: 2), 300_000,
                       "a skeleton that forgot its size would estimate three lines for 300 KB")
    }

    func testDecodingAPayloadClearsTheRecordedLengths() throws {
        let turn = makeTurn(user: ascii(2_000), blocks: [.text(ascii(5_000))])
        let skeleton = TurnPayloadStore.skeleton(of: turn)
        XCTAssertNotNil(skeleton.truncatedLengths)

        let payload = try XCTUnwrap(TurnPayloadStore.encodePayload(turn))
        let restored = try XCTUnwrap(TurnPayloadStore.decodePayload(payload, into: skeleton))

        XCTAssertNil(restored.truncatedLengths,
                     "a rehydrated turn measures itself; a stale recorded length would fight it")
        XCTAssertEqual(restored.userInputLength, 2_000)
        XCTAssertEqual(restored.contentLength(ofBlockAt: 0), 5_000)
    }

    func testRecordedLengthsUseTheSameUnitAsTheLivePathForUnicode() {
        let turn = makeTurn(user: Self.unicodeSample, blocks: [.text(Self.unicodeSample)])
        let skeleton = TurnPayloadStore.skeleton(of: turn)

        // Which unit lengths are counted in is not the requirement — the hot and
        // cold paths agreeing is. (They are UTF-8 bytes rather than graphemes:
        // `String.count` walks the string, and it runs on the streaming turn once
        // per arriving block, which made the cost of a token proportional to how
        // much that turn had already emitted.)
        //
        // Asserting against the live path rather than against a literal catches
        // the failure that actually matters: a skeleton that measured itself
        // differently from the turn it replaced would change height at the moment
        // it went cold, and the transcript would shift under the operator.
        XCTAssertEqual(skeleton.truncatedLengths?.userInput, turn.userInputLength)
        XCTAssertEqual(skeleton.contentLength(ofBlockAt: 0), turn.contentLength(ofBlockAt: 0))
        XCTAssertEqual(TurnHeightEstimator.estimate(skeleton, width: 800),
                       TurnHeightEstimator.estimate(turn, width: 800),
                       "a skeleton must hold exactly the place its turn held")
    }

    // MARK: - 4. The slope criterion

    /// The load-bearing measurement: what a long session costs in retained bytes.
    ///
    /// Retained bytes are (always-resident skeleton) + (compressed payload), the
    /// two things the store keeps once a turn goes cold. The criterion is
    /// ≤ 20 MB per 1,000 turns, and the corpus is the PRD's load profile: ~200
    /// character user message, 3–8 text blocks of 1–4 KB, 2–6 tool calls with
    /// ~2 KB results, and a ≥ 256 KB diff-like result on every twentieth turn.
    ///
    /// The RNG is seeded, so the number printed below is reproducible.
    func testRetainedBytesPerThousandTurnsStaysUnderTheBudget() {
        let corpus = SyntheticCorpus(seed: 0x5EED_1234)
        let turnCount = 5_000

        var skeletonBytes   = 0
        var compressedBytes = 0
        var rawBytes        = 0

        for seq in 0 ..< turnCount {
            let turn = corpus.turn(seq: seq)
            rawBytes += Self.rawBytes(of: turn)
            skeletonBytes += Self.retainedBytes(of: TurnPayloadStore.skeleton(of: turn))
            guard let payload = TurnPayloadStore.encodePayload(turn),
                  let blob = try? (payload as NSData).compressed(using: .lzfse) as Data else {
                return XCTFail("turn \(seq) failed to encode or compress")
            }
            compressedBytes += blob.count
        }

        let retained = skeletonBytes + compressedBytes
        let slopeMBPerThousand = Double(retained) / Double(turnCount) * 1_000 / (1_024 * 1_024)
        let rawSlope = Double(rawBytes) / Double(turnCount) * 1_000 / (1_024 * 1_024)

        let report = [
            "",
            "-- TurnPayloadStore retention, \(turnCount)-turn synthetic corpus (seed 0x5EED1234) --",
            "  raw, uncompressed : \(Self.mb(rawBytes)) MB (\(Self.perTurn(rawBytes, turnCount)) B/turn)",
            "  skeletons         : \(Self.mb(skeletonBytes)) MB (\(Self.perTurn(skeletonBytes, turnCount)) B/turn)",
            "  compressed payload: \(Self.mb(compressedBytes)) MB (\(Self.perTurn(compressedBytes, turnCount)) B/turn)",
            "  retained total    : \(Self.mb(retained)) MB",
            "  MEASURED SLOPE    : \(String(format: "%.2f", slopeMBPerThousand)) MB / 1,000 turns"
                + "  (criterion: <= 20.00)",
            "  raw would be      : \(String(format: "%.2f", rawSlope)) MB / 1,000 turns",
            // Not asserted — reported, because the retention cap is expressed in
            // turns and its memory consequence is only visible as a projection.
            "  skeletons alone at maxRetainedTurns (\(TurnPayloadStore.maxRetainedTurns)): "
                + "\(String(format: "%.0f", Double(skeletonBytes) / Double(turnCount) * Double(TurnPayloadStore.maxRetainedTurns) / (1_024 * 1_024))) MB",
            "",
        ].joined(separator: "\n")
        print(report)

        XCTAssertGreaterThan(rawSlope, slopeMBPerThousand,
                             "the corpus must be compressible enough for the measurement to mean anything")
        XCTAssertLessThanOrEqual(slopeMBPerThousand, 20.0,
                                 "retention slope exceeds the 20 MB / 1,000 turn criterion")
    }

    // MARK: Byte accounting

    /// Bytes a turn costs while it is fully resident. Deliberately generous
    /// about per-object overhead so the slope is not flattered.
    private static let turnOverhead  = 128   // id, dates, flags, TruncatedLengths box
    private static let blockOverhead = 48    // enum payload box + String header per block

    private static func rawBytes(of turn: ChatTurn) -> Int {
        turnOverhead
            + turn.userInput.utf8.count
            + turn.blocks.reduce(0) { $0 + blockOverhead + $1.payloadByteCount }
    }

    /// Same, plus the recorded original lengths a skeleton has to carry.
    private static func retainedBytes(of skeleton: ChatTurn) -> Int {
        rawBytes(of: skeleton) + 8 * (skeleton.truncatedLengths?.blocks.count ?? 0) + 8
    }

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / (1_024 * 1_024))
    }

    private static func perTurn(_ bytes: Int, _ turns: Int) -> Int { bytes / turns }

    // MARK: - 5. Hot turns pass straight through

    func testHydratingATurnThatWasNeverCompactedReturnsItUnchanged() {
        let store = TurnPayloadStore()
        let turn = makeTurn(user: "still hot", blocks: [.text(ascii(4_000))])

        guard let restored = assertFull(store.hydrate(turn)) else { return }
        XCTAssertEqual(restored.id, turn.id)
        XCTAssertEqual(restored.userInput, "still hot")
        guard case .text(let s)? = restored.blocks.first else { return XCTFail("block must survive") }
        XCTAssertEqual(s, ascii(4_000), "a hot turn must not be truncated on the way through")
        XCTAssertEqual(store.stats.coldTurns, 0)
    }

    func testCompactedTurnHydratesBackToItsFullContent() {
        let store = TurnPayloadStore()
        let prose = Self.unicodeSample + ascii(40_000)
        let output = ascii(260_000)
        let turn = makeTurn(user: ascii(1_000), blocks: [
            .text(prose),
            .toolCall(ToolCallData(toolName: "Bash", inputSummary: "ls", inputFull: ascii(9_000))),
            .toolResult(ToolResultData(content: output, isError: false)),
        ])

        guard let skeleton = compactAndWait(store, turn) else { return }
        XCTAssertLessThan(skeleton.userInput.count, turn.userInput.count,
                          "the completion must hand back the compacted turn")
        XCTAssertEqual(store.stats.coldTurns, 1)
        XCTAssertGreaterThan(store.stats.compressedBytes, 0)
        XCTAssertLessThan(store.stats.compressedBytes, output.utf8.count,
                          "a payload that grew is not a saving")

        guard let restored = assertFull(store.hydrate(skeleton)) else { return }
        XCTAssertEqual(restored.userInput, turn.userInput)
        guard restored.blocks.count == 3 else { return XCTFail("block shape must survive") }
        guard case .text(let s) = restored.blocks[0] else { return XCTFail("block 0") }
        XCTAssertEqual(s, prose)
        guard case .toolCall(let call) = restored.blocks[1] else { return XCTFail("block 1") }
        XCTAssertEqual(call.inputFull, ascii(9_000))
        guard case .toolResult(let result) = restored.blocks[2] else { return XCTFail("block 2") }
        XCTAssertEqual(result.content, output)
        XCTAssertNil(restored.truncatedLengths)
    }

    func testAnIncompleteTurnIsNeverCompacted() {
        let store = TurnPayloadStore()
        let turn = makeTurn(user: ascii(5_000), blocks: [.text(ascii(20_000))], complete: false)

        let never = expectation(description: "must not compact a streaming turn")
        never.isInverted = true
        store.compact(turn) { _ in never.fulfill() }
        wait(for: [never], timeout: 0.5)

        XCTAssertEqual(store.stats.coldTurns, 0,
                       "a turn that is still streaming can still grow; compressing it would lose the tail")
        guard let restored = assertFull(store.hydrate(turn)) else { return }
        XCTAssertEqual(restored.userInput, turn.userInput)
    }

    func testAMarkerTurnIsNeverCompacted() {
        let store = TurnPayloadStore()
        let never = expectation(description: "must not compact a marker")
        never.isInverted = true
        store.compact(ChatTurn.marker(.historyUnavailable)) { _ in never.fulfill() }
        wait(for: [never], timeout: 0.5)

        XCTAssertEqual(store.stats.coldTurns, 0)
    }

    // MARK: - 6. Dropped turns say so

    func testADroppedTurnReportsUnavailableRatherThanEmptyContent() {
        let store = TurnPayloadStore()
        let turn = makeTurn(user: ascii(1_000), blocks: [.text(ascii(30_000))])

        guard let skeleton = compactAndWait(store, turn) else { return }
        store.drop(turn.id)

        switch store.hydrate(skeleton) {
        case .full:
            XCTFail("a dropped payload must not be reported as full content")
        case .unavailable(let reported):
            XCTAssertEqual(reported.id, turn.id)
            XCTAssertFalse(reported.userInput.isEmpty,
                           "an unavailable turn still shows what it kept — never a blank expansion")
            guard case .text(let s)? = reported.blocks.first else {
                return XCTFail("the skeleton's blocks must survive being reported unavailable")
            }
            XCTAssertFalse(s.isEmpty, "never a silently-empty expansion")
            XCTAssertTrue(ascii(30_000).hasPrefix(s))
        }

        XCTAssertEqual(store.stats.coldTurns, 0, "dropping must actually release the bytes")
        XCTAssertEqual(store.stats.compressedBytes, 0)
    }

    func testADroppedTurnStaysUnavailableEvenIfCompactionIsRetried() {
        let store = TurnPayloadStore()
        let turn = makeTurn(user: ascii(1_000), blocks: [.text(ascii(30_000))])

        guard let skeleton = compactAndWait(store, turn) else { return }
        store.drop(turn.id)

        let never = expectation(description: "must not resurrect a dropped turn")
        never.isInverted = true
        store.compact(turn) { _ in never.fulfill() }
        wait(for: [never], timeout: 0.5)

        switch store.hydrate(skeleton) {
        case .full:    XCTFail("a dropped turn must stay dropped")
        case .unavailable: break
        }
    }

    // MARK: - 7. Pinning

    func testPinningPreventsCompactionAndUnpinningAllowsItAgain() {
        let store = TurnPayloadStore()
        let turn = makeTurn(user: ascii(1_000), blocks: [.text(ascii(30_000))])

        store.pin(turn.id)
        let never = expectation(description: "must not compact a materialized turn")
        never.isInverted = true
        store.compact(turn) { _ in never.fulfill() }
        wait(for: [never], timeout: 0.5)
        XCTAssertEqual(store.stats.coldTurns, 0,
                       "a turn with a live view on screen must keep its full content")

        store.unpin(turn.id)
        guard let skeleton = compactAndWait(store, turn) else { return }
        XCTAssertEqual(store.stats.coldTurns, 1)
        XCTAssertLessThan(skeleton.userInput.count, turn.userInput.count)
    }

    func testPinningOneTurnDoesNotProtectAnother() {
        let store = TurnPayloadStore()
        let pinnedTurn = makeTurn(seq: 1, user: ascii(1_000), blocks: [.text(ascii(30_000))])
        let otherTurn  = makeTurn(seq: 2, user: ascii(1_000), blocks: [.text(ascii(30_000))])

        store.pin(pinnedTurn.id)
        compactAndWait(store, otherTurn)

        XCTAssertEqual(store.stats.coldTurns, 1)
        guard let stillHot = assertFull(store.hydrate(pinnedTurn)) else { return }
        XCTAssertEqual(stillHot.userInput, pinnedTurn.userInput)
    }

    // MARK: - 8. Clear

    func testClearReleasesEverythingAndForgetsWhatWasDropped() {
        let store = TurnPayloadStore()
        let compacted = makeTurn(seq: 1, user: ascii(1_000), blocks: [.text(ascii(30_000))])
        let discarded = makeTurn(seq: 2, user: ascii(1_000), blocks: [.text(ascii(30_000))])

        guard let compactedSkeleton = compactAndWait(store, compacted) else { return }
        compactAndWait(store, discarded)
        store.drop(discarded.id)
        store.pin(compacted.id)
        XCTAssertEqual(store.stats.coldTurns, 1)

        store.clear()

        XCTAssertEqual(store.stats.coldTurns, 0)
        XCTAssertEqual(store.stats.compressedBytes, 0, "clear must actually release the bytes")

        // A cleared store knows nothing, so a turn handed to it is taken at face
        // value rather than reported as history that was dropped.
        switch store.hydrate(discarded) {
        case .full(let turn): XCTAssertEqual(turn.userInput, discarded.userInput)
        case .unavailable:    XCTFail("clear must reset the dropped set")
        }

        // …and the pin is gone too, so the turn can be compacted afresh.
        guard let again = compactAndWait(store, compacted) else { return }
        XCTAssertEqual(again.userInput.count, compactedSkeleton.userInput.count)
        XCTAssertEqual(store.stats.coldTurns, 1)
    }

    // MARK: - 9. Corrupt and mismatched blobs

    func testDecodingATruncatedBlobReturnsNilRatherThanPartialContent() throws {
        let turn = makeTurn(user: ascii(300), blocks: [.text(ascii(4_000)),
                                                       .text(ascii(2_000))])
        let payload = try XCTUnwrap(TurnPayloadStore.encodePayload(turn))

        for cut in [1, 4, 100, 2_000, payload.count - 4, payload.count - 1] {
            let truncated = payload.prefix(payload.count - cut)
            XCTAssertNil(TurnPayloadStore.decodePayload(Data(truncated), into: turn),
                         "a blob missing its last \(cut) bytes must not decode")
        }
    }

    func testDecodingAnEmptyOrStubBlobReturnsNil() {
        let turn = makeTurn(user: "x", blocks: [.text("y")])
        XCTAssertNil(TurnPayloadStore.decodePayload(Data(), into: turn))
        XCTAssertNil(TurnPayloadStore.decodePayload(Data([0, 0, 0]), into: turn))
        XCTAssertNil(TurnPayloadStore.decodePayload(Data([255, 255, 255, 255]), into: turn),
                     "a length prefix larger than the blob must be rejected, not trusted")
    }

    func testDecodingABlobWithTrailingGarbageReturnsNil() throws {
        let turn = makeTurn(user: "hello", blocks: [.text("world")])
        var payload = try XCTUnwrap(TurnPayloadStore.encodePayload(turn))
        payload.append(contentsOf: [7, 7, 7, 7])

        XCTAssertNil(TurnPayloadStore.decodePayload(payload, into: turn),
                     "bytes the skeleton cannot account for mean the blob is not this turn's")
    }

    func testDecodingAPayloadIntoTheWrongBlockShapeReturnsNil() throws {
        let source = makeTurn(user: "hello", blocks: [.text(ascii(500)), .text(ascii(500))])
        let payload = try XCTUnwrap(TurnPayloadStore.encodePayload(source))

        let tooManyBlocks = makeTurn(user: "hello", blocks: [.text(""), .text(""), .text("")])
        XCTAssertNil(TurnPayloadStore.decodePayload(payload, into: tooManyBlocks))

        let tooFewBlocks = makeTurn(user: "hello", blocks: [.text("")])
        XCTAssertNil(TurnPayloadStore.decodePayload(payload, into: tooFewBlocks))

        let wrongKinds = makeTurn(user: "hello", blocks: [
            .text(""),
            .resultSummary(ResultSummaryData(durationMs: 0, costUSD: 0, isError: false))])
        XCTAssertNil(TurnPayloadStore.decodePayload(payload, into: wrongKinds),
                     "a block that carries no payload must not consume one")
    }

    func testHydrateReportsUnavailableRatherThanEmptyWhenTheBlobIsUnusable() {
        // Exercised through the public surface: a store whose blob cannot be
        // turned back into this turn must say so, not hand back a blank turn.
        let store = TurnPayloadStore()
        let turn = makeTurn(user: ascii(1_000), blocks: [.text(ascii(20_000))])
        guard let skeleton = compactAndWait(store, turn) else { return }

        // Same view identity, incompatible block shape — what a reconcile that
        // reshaped a turn's blocks would produce.
        var reshaped = skeleton
        reshaped.blocks = skeleton.blocks + [.text("appended after compaction")]

        switch store.hydrate(reshaped) {
        case .full(let restored):
            XCTFail("a blob that does not fit the turn must not be reported as full; got \(restored.blocks.count) blocks")
        case .unavailable(let reported):
            XCTAssertFalse(reported.userInput.isEmpty, "never a silently-empty expansion")
        }
    }
}

// MARK: - Synthetic corpus

/// Generates the PRD's load profile deterministically.
///
/// Text is cut from a large pre-generated pool of word-sampled prose rather than
/// assembled word by word per turn: the local statistics a compressor sees are
/// the same, but the corpus builds in seconds instead of minutes. Compression is
/// per-turn, so repetition *across* turns cannot flatter the measurement.
private final class SyntheticCorpus {

    private var rng: SeededRNG
    private let prose: [UInt8]
    private let diff:  [UInt8]

    init(seed: UInt64) {
        var generator = SeededRNG(seed: seed)
        prose = SyntheticCorpus.buildProse(bytes: 4 << 20, rng: &generator)
        diff  = SyntheticCorpus.buildDiff(bytes: 2 << 20, rng: &generator)
        rng = generator
    }

    func turn(seq: Int) -> ChatTurn {
        var blocks: [TurnBlock] = []

        for _ in 0 ..< Int.random(in: 3 ... 8, using: &rng) {
            blocks.append(.text(slice(prose, bytes: Int.random(in: 1_024 ... 4_096, using: &rng))))
        }
        for _ in 0 ..< Int.random(in: 2 ... 6, using: &rng) {
            blocks.append(.toolCall(ToolCallData(
                toolName:     "Bash",
                inputSummary: slice(prose, bytes: Int.random(in: 20 ... 90, using: &rng)),
                inputFull:    slice(prose, bytes: Int.random(in: 300 ... 1_200, using: &rng)))))
            blocks.append(.toolResult(ToolResultData(
                content: slice(prose, bytes: Int.random(in: 1_500 ... 2_600, using: &rng)),
                isError: false)))
        }
        if seq % 20 == 0 {
            blocks.append(.toolResult(ToolResultData(
                content: slice(diff, bytes: Int.random(in: 262_144 ... 320_000, using: &rng)),
                isError: false)))
        }
        blocks.append(.resultSummary(ResultSummaryData(durationMs: 1_200, costUSD: 0.02,
                                                        isError: false)))

        return ChatTurn(userInput:    slice(prose, bytes: Int.random(in: 150 ... 260, using: &rng)),
                        timestamp:    Date(timeIntervalSince1970: 1_770_000_000 + Double(seq)),
                        timestampRaw: String(format: "2026-08-11T12:00:00.%06dZ", seq),
                        blocks:       blocks,
                        isComplete:   true,
                        daemonId:     "t\(seq)",
                        epoch:        0)
    }

    private func slice(_ pool: [UInt8], bytes: Int) -> String {
        let length = min(bytes, pool.count)
        let start = Int.random(in: 0 ... (pool.count - length), using: &rng)
        return String(decoding: pool[start ..< (start + length)], as: UTF8.self)
    }

    private static let vocabulary = """
    the of and to in a is that for it with as was on be at by this have from or \
    one had not but what all were when we there can an your which their said if \
    will each about how up out them then she many some so these would other into \
    has more her two like him see time could no make than first been its who now \
    people my over know water only new very after just where most any day thing \
    function return struct value error index buffer window layout height offset \
    virtualizer transcript daemon session snapshot reconcile estimate measured
    """.split(separator: " ").map { Array($0.utf8) }

    private static func buildProse(bytes: Int, rng: inout SeededRNG) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes + 64)
        var sinceBreak = 0
        while out.count < bytes {
            out.append(contentsOf: vocabulary[Int.random(in: 0 ..< vocabulary.count, using: &rng)])
            sinceBreak += 1
            if sinceBreak > Int.random(in: 8 ... 18, using: &rng) {
                out.append(0x0A)   // newline
                sinceBreak = 0
            } else {
                out.append(0x20)   // space
            }
        }
        return out
    }

    /// Diff-like output: hunk headers and +/- prefixed lines. Genuinely more
    /// repetitive than prose, which is exactly why a 256 KB diff is the shape
    /// the profile calls for.
    private static func buildDiff(bytes: Int, rng: inout SeededRNG) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes + 256)
        var line = 0
        while out.count < bytes {
            if line % 40 == 0 {
                out.append(contentsOf: Array("@@ -\(line),18 +\(line + 3),21 @@ func body() {\n".utf8))
            }
            let marker: UInt8 = [0x2B, 0x2D, 0x20][Int.random(in: 0 ..< 3, using: &rng)]
            out.append(marker)
            out.append(contentsOf: Array("    ".utf8))
            for _ in 0 ..< Int.random(in: 4 ... 12, using: &rng) {
                out.append(contentsOf: vocabulary[Int.random(in: 0 ..< vocabulary.count, using: &rng)])
                out.append(0x20)
            }
            out.append(0x0A)
            line += 1
        }
        return out
    }
}

/// xorshift64. Seeded so the slope number in the test output is reproducible.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        for _ in 0 ..< 8 { _ = next() }
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
