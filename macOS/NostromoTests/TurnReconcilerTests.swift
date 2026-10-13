import XCTest
// ChatTurn, TurnBlock and TurnReconciler are compiled into this target directly
// (logic test — no host app). No module imports needed.

// MARK: - TurnReconcilerTests

/// Behavioural tests for `TurnReconciler.reconcile(retained:snapshot:sessionIdChanged:)`.
///
/// The contract under test is stated entirely in terms of the reconciled
/// transcript: how many turns come back, which view identities (`ChatTurn.id`)
/// survive, whether any record entry appears twice, and what the daemon-side
/// address (`epoch`, `daemonId`) of each turn is afterwards. Nothing here
/// reaches into the reconciler's private helpers, so an internal rewrite of the
/// matching strategy should leave every one of these tests passing.
///
/// Two facts about the daemon shape these tests:
///
///  - Daemon turn ids (`t0`, `t1`, …) restart from zero on every daemon
///    restart, so they are *not* stable identity. `epoch` scopes them.
///  - A turn watched live carries a trailing `.resultSummary` block; the same
///    turn re-read from the stored session JSONL after a daemon restart does
///    not. Block shape therefore legitimately differs between two views of the
///    same record entry.
final class TurnReconcilerTests: XCTestCase {

    // MARK: - Fixtures

    private static let baseDate = Date(timeIntervalSince1970: 1_770_000_000)

    /// A stable, per-entry record timestamp. `timestampRaw` must be distinct
    /// per turn for identity to work, so it is derived from the sequence number
    /// and is identical for both views of the same record entry.
    private static func rawTimestamp(_ seq: Int) -> String {
        String(format: "2026-08-11T12:00:00.%04dZ", seq)
    }

    /// One record entry, identified by `seq`.
    ///
    /// `seq` is the entry's position in the underlying record — the thing that
    /// is stable across daemon restarts. Everything else (view id, daemon id,
    /// epoch, block shape) is a property of one *view* of that entry and is
    /// free to differ between the retained list and the snapshot.
    private func makeTurn(seq: Int,
                          text: String? = nil,
                          epoch: Int = 0,
                          daemonId: String? = nil,
                          blocks: [TurnBlock] = [],
                          complete: Bool = true) -> ChatTurn {
        ChatTurn(userInput:    text ?? "message \(seq)",
                 timestamp:    Self.baseDate.addingTimeInterval(Double(seq)),
                 timestampRaw: Self.rawTimestamp(seq),
                 blocks:       blocks,
                 isComplete:   complete,
                 daemonId:     daemonId ?? "t\(seq)",
                 epoch:        epoch)
    }

    /// What the client is already holding. Daemon ids are prefixed `r` by
    /// default so that "adopted the snapshot's daemon id" is unambiguous.
    private func makeRetained(_ seqs: [Int],
                              epoch: Int = 0,
                              daemonIdPrefix: String = "r",
                              text: ((Int) -> String)? = nil,
                              blocks: [TurnBlock] = []) -> [ChatTurn] {
        seqs.map { seq in
            makeTurn(seq: seq, text: text?(seq), epoch: epoch,
                     daemonId: "\(daemonIdPrefix)\(seq)", blocks: blocks)
        }
    }

    /// A daemon attach snapshot of the same record entries: fresh view ids, and
    /// daemon ids re-issued from `t0` — exactly what a restarted daemon sends.
    private func makeSnapshot(_ seqs: [Int],
                              epoch: Int,
                              text: ((Int) -> String)? = nil,
                              blocks: [TurnBlock] = []) -> [ChatTurn] {
        seqs.enumerated().map { (index, seq) in
            makeTurn(seq: seq, text: text?(seq), epoch: epoch,
                     daemonId: "t\(index)", blocks: blocks)
        }
    }

    /// A locally-created turn the daemon has not acknowledged yet: no record
    /// entry, so no daemon id and no record timestamp.
    private func makeOptimisticEcho(text: String) -> ChatTurn {
        ChatTurn(userInput: text, timestamp: Self.baseDate,
                 timestampRaw: nil, blocks: [], isComplete: false,
                 daemonId: nil, epoch: 0)
    }

    private var resultSummaryBlock: TurnBlock {
        .resultSummary(ResultSummaryData(durationMs: 1_200, costUSD: 0.02, isError: false))
    }

    // MARK: - Assertion helpers

    /// No record entry may appear twice in the transcript. Markers are
    /// synthetic and belong to no record entry, so they are excluded.
    private func assertNoDuplicateEntries(_ turns: [ChatTurn],
                                          _ message: String = "",
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        let keys = turns.filter { $0.marker == nil }.map { $0.identityKey }
        let counts = Dictionary(grouping: keys, by: { $0 }).mapValues(\.count)
        let dupes = counts.filter { $0.value > 1 }.keys.sorted()
        XCTAssertTrue(dupes.isEmpty,
                      "\(message) record entries duplicated in the transcript: \(dupes)",
                      file: file, line: line)
    }

    private func assertUniqueViewIdentities(_ turns: [ChatTurn],
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        let ids = turns.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count,
                       "every turn must have a distinct view id",
                       file: file, line: line)
    }

    /// `replacedFrom` promises that everything before it is untouched — same
    /// turns, same view ids, same order — so the view layer need not rebuild it.
    private func assertPrefixBeforeReplacedFromIsUntouched(
        _ outcome: TurnReconciler.Outcome,
        retained: [ChatTurn],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(outcome.replacedFrom, outcome.turns.count,
                                 "replacedFrom must index into the reconciled list",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(outcome.replacedFrom, retained.count,
                                 "replacedFrom must index into the retained list",
                                 file: file, line: line)
        for i in 0 ..< min(outcome.replacedFrom, min(retained.count, outcome.turns.count)) {
            XCTAssertEqual(outcome.turns[i].id, retained[i].id,
                           "turn \(i) is before replacedFrom (\(outcome.replacedFrom)) "
                           + "so its view identity must be untouched",
                           file: file, line: line)
            XCTAssertEqual(outcome.turns[i].identityKey, retained[i].identityKey,
                           "turn \(i) is before replacedFrom (\(outcome.replacedFrom)) "
                           + "so it must still be the same record entry",
                           file: file, line: line)
        }
    }

    private func gapMarkerCount(_ turns: [ChatTurn]) -> Int {
        turns.filter { $0.isGapMarker }.count
    }

    /// Guards the positional assertions below. A wrong turn count is itself a
    /// failure worth reporting, and bailing out keeps a regression from
    /// trapping on an out-of-range subscript and taking the whole suite down.
    private func requireCount(_ turns: [ChatTurn], _ expected: Int,
                              _ message: String = "",
                              file: StaticString = #filePath,
                              line: UInt = #line) -> Bool {
        guard turns.count == expected else {
            XCTFail("expected \(expected) turns, got \(turns.count). \(message)",
                    file: file, line: line)
            return false
        }
        return true
    }

    // MARK: - 1. Full overlap

    func testFullyOverlappingSnapshotPreservesEveryTurnAndAdoptsTheNewDaemonAddress() {
        let retained = makeRetained(Array(0 ..< 30))
        let snapshot = makeSnapshot(Array(0 ..< 30), epoch: 1)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.turns.count, 30,
                       "a snapshot that fully overlaps the retained list adds no turns")
        XCTAssertEqual(outcome.overlap, 30,
                       "all 30 retained turns overlap the snapshot")
        XCTAssertFalse(outcome.didReplaceAll,
                       "common ground was found, so nothing was replaced wholesale")
        XCTAssertFalse(outcome.insertedGapMarker,
                       "no history is missing, so no gap marker belongs here")

        XCTAssertEqual(outcome.turns.map { $0.id }, retained.map { $0.id },
                       "every view identity must carry forward across the reattach — "
                       + "this is what stops ReplView leaking a fresh set of turn views")
        XCTAssertEqual(outcome.turns.map { $0.identityKey },
                       retained.map { $0.identityKey },
                       "the transcript must still describe the same record entries in order")

        for (index, turn) in outcome.turns.enumerated() {
            XCTAssertEqual(turn.epoch, 1,
                           "turn \(index) must adopt the snapshot's epoch")
            XCTAssertEqual(turn.daemonId, "t\(index)",
                           "turn \(index) must adopt the snapshot's re-issued daemon id")
        }

        assertNoDuplicateEntries(outcome.turns)
        assertUniqueViewIdentities(outcome.turns)
        assertPrefixBeforeReplacedFromIsUntouched(outcome, retained: retained)
    }

    // MARK: - 2. Partial overlap

    func testPartiallyOverlappingSnapshotAppendsOnlyTheNewTurns() {
        let retained = makeRetained(Array(0 ..< 30))              // entries 0…29
        let snapshot = makeSnapshot(Array(20 ..< 50), epoch: 1)   // entries 20…49

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.overlap, 10,
                       "the last 10 retained turns are the snapshot's first 10")
        guard requireCount(outcome.turns, 50,
                           "30 retained + 20 genuinely new turns; the 10 shared ones splice")
        else { return }
        XCTAssertEqual(outcome.turns.map { $0.identityKey },
                       (0 ..< 50).map { Self.rawTimestamp($0) + "|message \($0)" },
                       "the reconciled transcript must be entries 0…49 in record order")

        for i in 20 ..< 30 {
            XCTAssertEqual(outcome.turns[i].id, retained[i].id,
                           "overlapping entry \(i) must keep its original view identity")
        }

        assertNoDuplicateEntries(outcome.turns)
        assertUniqueViewIdentities(outcome.turns)
        XCTAssertFalse(outcome.didReplaceAll)
        XCTAssertFalse(outcome.insertedGapMarker)
        assertPrefixBeforeReplacedFromIsUntouched(outcome, retained: retained)
    }

    // MARK: - 3. The V3 regression: repeated reconnects must not grow the transcript

    func testTwentySequentialReconnectsLeaveTheTranscriptExactlyAsItWas() {
        var current = makeRetained(Array(0 ..< 30))
        let originalIds = current.map { $0.id }
        var observedCounts: [Int] = []

        for round in 1 ... 20 {
            // Each reconnect delivers the same 30 record entries with fresh view
            // ids, a new epoch, and daemon ids re-issued from t0.
            let snapshot = makeSnapshot(Array(0 ..< 30), epoch: round)
            let outcome = TurnReconciler.reconcile(retained: current,
                                                   snapshot: snapshot,
                                                   sessionIdChanged: false)
            current = outcome.turns
            observedCounts.append(current.count)

            XCTAssertEqual(current.map { $0.id }, originalIds,
                           "round \(round): view identity must be stable across every "
                           + "reconnect — a fresh UUID per turn per reconnect is exactly "
                           + "the leak that put 123 GB resident")
            XCTAssertEqual(outcome.overlap, 30, "round \(round)")
            XCTAssertFalse(outcome.didReplaceAll, "round \(round)")
            XCTAssertFalse(outcome.insertedGapMarker, "round \(round)")
            XCTAssertEqual(gapMarkerCount(current), 0, "round \(round)")
            assertNoDuplicateEntries(current, "round \(round):")
            assertUniqueViewIdentities(current)

            for (index, turn) in current.enumerated() {
                XCTAssertEqual(turn.epoch, round,
                               "round \(round): turn \(index) must carry the current epoch")
            }
        }

        XCTAssertEqual(Set(observedCounts), [30],
                       "turn count must be strictly constant across all 20 reconnects, "
                       + "got \(observedCounts)")
    }

    func testRepeatedReconnectsWithoutOverlapDoNotAccumulateGapMarkers() {
        // A reconnect with no common ground legitimately inserts one gap marker.
        // Reconnecting again against the same snapshot must not insert another.
        var current = makeRetained(Array(0 ..< 30))
        let snapshot = makeSnapshot(Array(100 ..< 130), epoch: 1)

        let first = TurnReconciler.reconcile(retained: current, snapshot: snapshot,
                                             sessionIdChanged: false)
        current = first.turns
        XCTAssertEqual(gapMarkerCount(current), 1,
                       "the first no-overlap reconnect states the missing history once")

        for round in 2 ... 10 {
            let outcome = TurnReconciler.reconcile(retained: current,
                                                   snapshot: makeSnapshot(Array(100 ..< 130),
                                                                          epoch: round),
                                                   sessionIdChanged: false)
            current = outcome.turns
            XCTAssertEqual(gapMarkerCount(current), 1,
                           "round \(round): the same gap must not be restated")
            XCTAssertEqual(current.count, first.turns.count,
                           "round \(round): transcript length must be stable")
            assertNoDuplicateEntries(current, "round \(round):")
        }
    }

    // MARK: - 4. The V4 regression: cross-epoch daemon id collision

    func testReIssuedDaemonIdsAreScopedByEpochSoLookupsCannotHitAncientTurns() {
        // 500 turns held from epoch 0, addressed t0…t499.
        let retained = makeRetained(Array(0 ..< 500), epoch: 0, daemonIdPrefix: "t")
        // The daemon restarted; its 30-turn attach window re-issues ids from t0
        // for entries 470…499 — entries we already hold under ids t470…t499.
        let snapshot = makeSnapshot(Array(470 ..< 500), epoch: 1)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.overlap, 30)
        assertNoDuplicateEntries(outcome.turns)
        assertUniqueViewIdentities(outcome.turns)
        guard requireCount(outcome.turns, 500,
                           "the snapshot re-describes turns we already hold; none are new")
        else { return }

        for (offset, index) in (470 ..< 500).enumerated() {
            XCTAssertEqual(outcome.turns[index].epoch, 1,
                           "overlapping turn \(index) must adopt the new epoch")
            XCTAssertEqual(outcome.turns[index].daemonId, "t\(offset)",
                           "overlapping turn \(index) must adopt the snapshot's re-issued id")
            XCTAssertEqual(outcome.turns[index].id, retained[index].id,
                           "overlapping turn \(index) must keep its view identity")
        }

        for index in 0 ..< 470 {
            XCTAssertEqual(outcome.turns[index].epoch, 0,
                           "turn \(index) predates the snapshot window and keeps its epoch")
        }

        // Mirror the lookup ChatSession does when routing an incoming delta.
        let currentEpoch = 1
        let hits = outcome.turns.filter { $0.daemonId == "t3" && $0.epoch == currentEpoch }
        XCTAssertEqual(hits.count, 1,
                       "daemon id 't3' scoped to the current epoch must be unambiguous "
                       + "even though an epoch-0 turn also answers to 't3'")
        XCTAssertEqual(hits.first?.identityKey,
                       Self.rawTimestamp(473) + "|message 473",
                       "'t3' at epoch 1 is the fourth turn of the new snapshot (entry 473), "
                       + "not the ancient entry 3")

        // And the ancient turn is still reachable under its own epoch.
        let ancient = outcome.turns.filter { $0.daemonId == "t3" && $0.epoch == 0 }
        XCTAssertEqual(ancient.count, 1)
        XCTAssertEqual(ancient.first?.identityKey,
                       Self.rawTimestamp(3) + "|message 3")

        assertPrefixBeforeReplacedFromIsUntouched(outcome, retained: retained)
    }

    // MARK: - 5. Block shape differs across the reconnect boundary

    func testTurnsStillMatchWhenTheSnapshotLacksTheLiveResultSummaryBlock() {
        // Watched live, each turn ended with a resultSummary block. Re-read from
        // the stored session JSONL after a daemon restart, it does not — the
        // stored record has no `result` lines.
        let retained = makeRetained(Array(0 ..< 30),
                                    blocks: [.text("done"), resultSummaryBlock])
        let snapshot = makeSnapshot(Array(0 ..< 30), epoch: 1,
                                    blocks: [.text("done")])

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.overlap, 30,
                       "differing block shape must not defeat the match — identity is "
                       + "(record timestamp, user text), not block shape")
        XCTAssertEqual(outcome.turns.count, 30,
                       "nothing may be duplicated just because the blocks differ")
        XCTAssertEqual(outcome.turns.map { $0.id }, retained.map { $0.id },
                       "view identity must survive the block-shape difference")
        XCTAssertFalse(outcome.insertedGapMarker)
        XCTAssertFalse(outcome.didReplaceAll)
        assertNoDuplicateEntries(outcome.turns)
    }

    func testTurnsStillMatchWhenTheSnapshotHasADifferentNumberOfDurableBlocks() {
        // A turn interrupted mid-stream differs by however many blocks had
        // arrived — a *durable* difference that survives into the stored record.
        // Identity is (record timestamp, user text), so it must still match.
        let interrupted: [TurnBlock] = [
            .text("working on it"),
            .toolCall(ToolCallData(toolName: "Read", inputSummary: "ChatModels.swift",
                                   inputFull: "{}")),
        ]
        let complete: [TurnBlock] = interrupted + [
            .toolResult(ToolResultData(content: "…file…", isError: false)),
            .text("done"),
        ]
        let retained = makeRetained(Array(0 ..< 30), blocks: interrupted)
        let snapshot = makeSnapshot(Array(0 ..< 30), epoch: 1, blocks: complete)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.overlap, 30,
                       "a turn that gained blocks since we last saw it is still the same "
                       + "turn — matching must not depend on block shape")
        XCTAssertEqual(outcome.turns.count, 30)
        XCTAssertEqual(outcome.turns.map { $0.id }, retained.map { $0.id })
        XCTAssertEqual(outcome.turns.first?.blocks.count, complete.count,
                       "the snapshot's fuller view of the turn wins on content")
        XCTAssertFalse(outcome.insertedGapMarker)
        assertNoDuplicateEntries(outcome.turns)
    }

    // MARK: - 6. Repeated identical user input at the splice boundary

    func testRepeatedIdenticalUserInputAtTheBoundarySplicesAtTheLongestOverlap() {
        // Entries 5…9 are all the word "yes" — distinguished only by their
        // record timestamps.
        let yes: (Int) -> String = { seq in seq >= 5 ? "yes" : "message \(seq)" }
        let retained = makeRetained(Array(0 ..< 10), text: yes)
        let snapshot = makeSnapshot(Array(5 ..< 13), epoch: 1, text: yes)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.overlap, 5,
                       "the longest overlap is the five 'yes' turns, entries 5…9")
        guard requireCount(outcome.turns, 13,
                           "entries 0…12: nothing dropped, nothing repeated")
        else { return }
        XCTAssertEqual(outcome.turns.map { $0.identityKey },
                       (0 ..< 13).map { Self.rawTimestamp($0) + "|" + yes($0) },
                       "a run of identical messages must splice in the right place — "
                       + "misalignment here would silently reorder the transcript")

        for i in 5 ..< 10 {
            XCTAssertEqual(outcome.turns[i].id, retained[i].id,
                           "overlapping 'yes' turn \(i) must keep its view identity")
        }

        assertNoDuplicateEntries(outcome.turns)
        assertUniqueViewIdentities(outcome.turns)
        XCTAssertFalse(outcome.insertedGapMarker)
        assertPrefixBeforeReplacedFromIsUntouched(outcome, retained: retained)
    }

    func testAmbiguousRunOfIdenticalTurnsSplicesAtTheLongestOverlap() {
        // Record timestamps are not always fine-grained enough to separate two
        // identical messages sent in quick succession. When the tail is genuinely
        // ambiguous, the splice must take the *longest* consistent overlap —
        // taking the shortest would re-append a turn we already hold.
        func ambiguousYes(id: UUID = UUID(), daemonId: String) -> ChatTurn {
            ChatTurn(id: id, userInput: "yes",
                     timestamp: Self.baseDate.addingTimeInterval(8),
                     timestampRaw: Self.rawTimestamp(8),
                     blocks: [], isComplete: true, daemonId: daemonId, epoch: 0)
        }

        let head = makeRetained(Array(0 ..< 8))
        let firstYes  = ambiguousYes(daemonId: "r8")
        let secondYes = ambiguousYes(daemonId: "r9")
        let retained  = head + [firstYes, secondYes]

        let snapshot = [ambiguousYes(daemonId: "t0"),
                        ambiguousYes(daemonId: "t1"),
                        makeTurn(seq: 9, epoch: 1, daemonId: "t2")]

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.overlap, 2,
                       "both ambiguous turns overlap the snapshot, not just the last one")
        guard requireCount(outcome.turns, 11,
                           "8 leading turns + the 2 ambiguous ones + 1 new turn")
        else { return }
        XCTAssertEqual(outcome.turns.filter { $0.userInput == "yes" }.count, 2,
                       "a run of identical messages must not gain a phantom repetition")
        XCTAssertEqual(outcome.turns[8].id, firstYes.id,
                       "the earlier ambiguous turn keeps its view identity")
        XCTAssertEqual(outcome.turns[9].id, secondYes.id,
                       "the later ambiguous turn keeps its view identity")
        assertUniqueViewIdentities(outcome.turns)
    }

    // MARK: - 7. No overlap, different session

    func testNoOverlapWithChangedSessionIdReplacesTheTranscriptWholesale() {
        let retained = makeRetained(Array(0 ..< 30))
        let snapshot = makeSnapshot(Array(100 ..< 130), epoch: 1)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: true)

        XCTAssertTrue(outcome.didReplaceAll,
                      "a different conversation: retained history belongs to the old one "
                      + "and its turn views must be cleared")
        XCTAssertEqual(outcome.overlap, 0)
        XCTAssertFalse(outcome.insertedGapMarker,
                       "nothing is missing from *this* conversation, so no gap marker")
        XCTAssertEqual(gapMarkerCount(outcome.turns), 0)
        XCTAssertEqual(outcome.turns.map { $0.id }, snapshot.map { $0.id },
                       "the result is exactly the snapshot")
        XCTAssertEqual(outcome.turns.map { $0.identityKey },
                       snapshot.map { $0.identityKey })
        XCTAssertEqual(outcome.replacedFrom, 0,
                       "everything changed, from the first turn onwards")
    }

    // MARK: - 8. No overlap, same (or unknown) session

    func testNoOverlapWithSameSessionKeepsHistoryAndStatesTheGap() {
        let retained = makeRetained(Array(0 ..< 30))
        let snapshot = makeSnapshot(Array(100 ..< 130), epoch: 1)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertFalse(outcome.didReplaceAll,
                       "same record — history must never be dropped on the strength of "
                       + "an absent session id")
        XCTAssertTrue(outcome.insertedGapMarker)
        XCTAssertEqual(outcome.overlap, 0)

        XCTAssertEqual(gapMarkerCount(outcome.turns), 1,
                       "exactly one gap marker, not one per missing turn")
        XCTAssertEqual(outcome.turns.firstIndex(where: { $0.isGapMarker }), 30,
                       "the marker sits between the retained history and the snapshot")
        assertNoDuplicateEntries(outcome.turns)

        guard requireCount(outcome.turns, 61,
                           "30 retained + 1 gap marker + 30 snapshot turns")
        else { return }

        // No history was dropped.
        XCTAssertEqual(outcome.turns.prefix(30).map { $0.id }, retained.map { $0.id },
                       "every retained turn survives, with its view identity intact")
        XCTAssertEqual(outcome.turns.suffix(30).map { $0.identityKey },
                       snapshot.map { $0.identityKey },
                       "the snapshot is appended after the marker")

        assertUniqueViewIdentities(outcome.turns)
        assertPrefixBeforeReplacedFromIsUntouched(outcome, retained: retained)
    }

    // MARK: - 9. Empty snapshot

    func testEmptySnapshotLeavesTheTranscriptUntouched() {
        let retained = makeRetained(Array(0 ..< 30))

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: [],
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.turns.map { $0.id }, retained.map { $0.id },
                       "a daemon that has read no turns yet must not erase the transcript")
        XCTAssertEqual(outcome.turns.map { $0.identityKey },
                       retained.map { $0.identityKey })
        XCTAssertEqual(outcome.turns.map { $0.epoch }, retained.map { $0.epoch },
                       "an empty snapshot carries no new daemon address to adopt")
        XCTAssertFalse(outcome.didReplaceAll)
        XCTAssertFalse(outcome.insertedGapMarker)
        XCTAssertEqual(outcome.overlap, 0)
        XCTAssertEqual(outcome.replacedFrom, retained.count,
                       "nothing changed, so nothing needs re-rendering")
        assertPrefixBeforeReplacedFromIsUntouched(outcome, retained: retained)
    }

    func testEmptySnapshotAgainstEmptyRetainedIsANoOp() {
        let outcome = TurnReconciler.reconcile(retained: [], snapshot: [],
                                               sessionIdChanged: true)
        XCTAssertTrue(outcome.turns.isEmpty)
        XCTAssertFalse(outcome.didReplaceAll)
        XCTAssertEqual(outcome.overlap, 0)
    }

    // MARK: - 10. Empty retained

    func testEmptyRetainedAdoptsTheSnapshot() {
        let snapshot = makeSnapshot(Array(0 ..< 30), epoch: 1)

        let outcome = TurnReconciler.reconcile(retained: [], snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.overlap, 0,
                       "a client that holds nothing overlaps nothing")
        XCTAssertEqual(outcome.turns.map { $0.id }, snapshot.map { $0.id },
                       "the snapshot is adopted as-is")
        XCTAssertEqual(outcome.turns.map { $0.identityKey },
                       snapshot.map { $0.identityKey })
        XCTAssertFalse(outcome.didReplaceAll,
                       "there were no turn views to clear")
        XCTAssertFalse(outcome.insertedGapMarker,
                       "no history is missing — we simply had none")
        XCTAssertEqual(outcome.replacedFrom, 0)
    }

    // MARK: - 11. Reverse containment — the snapshot reaches further back

    func testSnapshotThatStrictlyContainsTheRetainedTailIsAdoptedWholesale() {
        // We hold only entries 25…29; the daemon's window covers 0…29.
        let retained = makeRetained(Array(25 ..< 30))
        let snapshot = makeSnapshot(Array(0 ..< 30), epoch: 1)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.overlap, 5,
                       "our whole list is the snapshot's tail")
        XCTAssertFalse(outcome.insertedGapMarker,
                       "no history is missing between the two — nothing to state")
        XCTAssertEqual(gapMarkerCount(outcome.turns), 0)
        XCTAssertFalse(outcome.didReplaceAll,
                       "common ground was found; the retained turns were not discarded")

        XCTAssertEqual(outcome.turns.map { $0.identityKey },
                       (0 ..< 30).map { Self.rawTimestamp($0) + "|message \($0)" })

        guard requireCount(outcome.turns, 30,
                           "adopting the snapshot is a strict gain of history")
        else { return }
        for (offset, index) in (25 ..< 30).enumerated() {
            XCTAssertEqual(outcome.turns[index].id, retained[offset].id,
                           "overlapping entry \(index) must keep its view identity even "
                           + "though the snapshot was adopted wholesale")
        }

        assertNoDuplicateEntries(outcome.turns)
        assertUniqueViewIdentities(outcome.turns)
    }

    // MARK: - 12. Trailing optimistic echoes

    func testTrailingOptimisticEchoStaysAtTheBottomAcrossAReconcile() {
        let body = makeRetained(Array(0 ..< 10))
        let echo = makeOptimisticEcho(text: "run the tests")
        let retained = body + [echo]
        let snapshot = makeSnapshot(Array(0 ..< 10), epoch: 1)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.turns.count, 11,
                       "the pending message the operator just sent must not vanish")
        XCTAssertEqual(outcome.turns.last?.id, echo.id,
                       "the un-acknowledged echo stays pinned to the bottom, where the "
                       + "operator put it")
        XCTAssertNil(outcome.turns.last?.daemonId,
                     "the echo is still un-acknowledged after the reconcile")
        XCTAssertEqual(outcome.overlap, 10,
                       "a trailing echo must not force a spurious no-overlap verdict")
        XCTAssertFalse(outcome.didReplaceAll)
        XCTAssertFalse(outcome.insertedGapMarker)
        XCTAssertEqual(outcome.turns.prefix(10).map { $0.id }, body.map { $0.id },
                       "the acknowledged turns still carry their view identity")
        assertUniqueViewIdentities(outcome.turns)
    }

    func testTrailingOptimisticEchoIsNotDuplicatedWhenTheSnapshotAlreadyRecordedIt() {
        let body = makeRetained(Array(0 ..< 10))
        let echo = makeOptimisticEcho(text: "run the tests")
        let retained = body + [echo]
        // The daemon did receive it: entry 10 is that same message, recorded.
        let snapshot = makeSnapshot(Array(0 ..< 11), epoch: 1,
                                    text: { $0 == 10 ? "run the tests" : "message \($0)" })

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.turns.filter { $0.userInput == "run the tests" }.count, 1,
                       "the operator's message must appear once, not twice — the recorded "
                       + "turn supersedes the optimistic echo")
        XCTAssertEqual(outcome.turns.count, 11)
        XCTAssertEqual(outcome.turns.last?.userInput, "run the tests",
                       "the message is still the last thing in the transcript")
        XCTAssertEqual(outcome.turns.last?.daemonId, "t10",
                       "and it is now the daemon-acknowledged turn, not the echo")
        assertNoDuplicateEntries(outcome.turns)
        assertUniqueViewIdentities(outcome.turns)
    }

    // MARK: - 13. replacedFrom is accurate

    func testReplacedFromMarksExactlyTheUnchangedPrefixOnAPartialOverlap() {
        let retained = makeRetained(Array(0 ..< 30))
        let snapshot = makeSnapshot(Array(20 ..< 50), epoch: 1)

        let outcome = TurnReconciler.reconcile(retained: retained,
                                               snapshot: snapshot,
                                               sessionIdChanged: false)

        XCTAssertEqual(outcome.replacedFrom, 20,
                       "entries 0…19 are untouched; the splice begins at entry 20")
        assertPrefixBeforeReplacedFromIsUntouched(outcome, retained: retained)

        // And the claim is tight: the turn *at* replacedFrom did change (it took
        // the snapshot's daemon address), so it is right to re-render from there.
        guard outcome.turns.count > 20 else { return }
        XCTAssertEqual(outcome.turns[20].epoch, 1)
        XCTAssertNotEqual(outcome.turns[20].daemonId, retained[20].daemonId)
    }

    func testReplacedFromHoldsAcrossEveryReconcileShape() {
        let retained = makeRetained(Array(0 ..< 30))

        let cases: [(name: String, snapshot: [ChatTurn], sessionIdChanged: Bool)] = [
            ("full overlap",     makeSnapshot(Array(0 ..< 30),    epoch: 1), false),
            ("partial overlap",  makeSnapshot(Array(20 ..< 50),   epoch: 1), false),
            ("single-turn tail", makeSnapshot(Array(29 ..< 40),   epoch: 1), false),
            ("empty snapshot",   [],                                          false),
            ("gap inserted",     makeSnapshot(Array(100 ..< 130), epoch: 1), false),
            ("replaced all",     makeSnapshot(Array(100 ..< 130), epoch: 1), true),
        ]

        for c in cases {
            let outcome = TurnReconciler.reconcile(retained: retained,
                                                   snapshot: c.snapshot,
                                                   sessionIdChanged: c.sessionIdChanged)
            XCTAssertPrefixContract(outcome, retained: retained, label: c.name)
        }
    }

    /// Wrapper so the failure message names the scenario.
    private func XCTAssertPrefixContract(_ outcome: TurnReconciler.Outcome,
                                         retained: [ChatTurn],
                                         label: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        XCTAssertLessThanOrEqual(outcome.replacedFrom, outcome.turns.count,
                                 "\(label): replacedFrom out of range", file: file, line: line)
        for i in 0 ..< min(outcome.replacedFrom, min(retained.count, outcome.turns.count)) {
            XCTAssertEqual(outcome.turns[i].id, retained[i].id,
                           "\(label): turn \(i) is before replacedFrom and must be untouched",
                           file: file, line: line)
            XCTAssertEqual(outcome.turns[i].identityKey, retained[i].identityKey,
                           "\(label): turn \(i) is before replacedFrom and must be the "
                           + "same record entry", file: file, line: line)
        }
        if outcome.didReplaceAll {
            XCTAssertEqual(outcome.replacedFrom, 0,
                           "\(label): a wholesale replacement changes everything",
                           file: file, line: line)
        }
    }

    // MARK: - The shrink invariant
    //
    // A load run showed a pane's retained turn count going 57 -> 2 and then
    // refilling. `ChatSession` has exactly three writers that can shorten
    // `turns`: `newSession()` (every call site is a click), `enforceRetentionCap`
    // (needs more than 10,000 turns), and `turns = outcome.turns` here. These
    // tests pin the third one shut, so the next time it happens the reconciler
    // is not a suspect.

    func testReconcileNeverReturnsFewerTurnsThanItWasGiven() {
        // Every shape the reconciler can take, over a range of sizes and
        // overlaps. The only sanctioned way to lose history is a changed session
        // id, which is covered separately below.
        for retainedCount in [0, 1, 2, 5, 30, 60] {
            for snapshotStart in [0, 1, 5, 29, 30, 45, 100] {
                for snapshotCount in [0, 1, 2, 30] {
                    let retained = makeRetained(Array(0 ..< retainedCount))
                    let snapshot = makeSnapshot(
                        Array(snapshotStart ..< (snapshotStart + snapshotCount)), epoch: 1)
                    let outcome = TurnReconciler.reconcile(retained: retained,
                                                           snapshot: snapshot,
                                                           sessionIdChanged: false)
                    XCTAssertGreaterThanOrEqual(
                        outcome.turns.count, retained.count,
                        """
                        reconcile shed history with an unchanged session id: \
                        retained=\(retainedCount) snapshot=\(snapshotStart)..<\
                        \(snapshotStart + snapshotCount) -> \(outcome.turns.count)
                        """)
                    XCTAssertFalse(outcome.didReplaceAll,
                                   "an unchanged session id must never replace wholesale")
                }
            }
        }
    }

    func testEveryRetainedIdentitySurvivesWhenTheSessionIdIsUnchanged() {
        // Stronger than a count check: no turn may be silently dropped from the
        // middle either.
        for snapshotStart in [0, 10, 25, 30, 80] {
            let retained = makeRetained(Array(0 ..< 30))
            let snapshot = makeSnapshot(Array(snapshotStart ..< (snapshotStart + 30)), epoch: 1)
            let outcome = TurnReconciler.reconcile(retained: retained,
                                                   snapshot: snapshot,
                                                   sessionIdChanged: false)
            let survivors = Set(outcome.turns.map { $0.identityKey })
            for turn in retained {
                XCTAssertTrue(survivors.contains(turn.identityKey),
                              "lost \(turn.identityKey) at snapshotStart=\(snapshotStart)")
            }
        }
    }

    func testOnlyAChangedSessionIdCanShortenTheTranscript() {
        let retained = makeRetained(Array(0 ..< 30))
        let snapshot = makeSnapshot([900, 901], epoch: 1)

        let kept = TurnReconciler.reconcile(retained: retained, snapshot: snapshot,
                                            sessionIdChanged: false)
        XCTAssertGreaterThan(kept.turns.count, retained.count,
                             "same record: keep history and state the gap")
        XCTAssertTrue(kept.insertedGapMarker)

        let replaced = TurnReconciler.reconcile(retained: retained, snapshot: snapshot,
                                                sessionIdChanged: true)
        XCTAssertEqual(replaced.turns.count, snapshot.count,
                       "a different conversation is the one case history may go")
        XCTAssertTrue(replaced.didReplaceAll)
    }
}

// MARK: - Tool-fold wire enrichment (TF1): the Mac's own wire decode

/// The Mac decodes the daemon's blocks with its own `DaemonTurnBlock` (NostromoKit has a
/// twin; its tests are in `ClientMsgTests`). The optional keys are `tool_use_id`,
/// `parent_tool_use_id`, `target` and `ts`; an older daemon sends none of them.
final class DaemonTurnBlockToolMetaDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> DaemonTurnBlock {
        try JSONDecoder().decode(DaemonTurnBlock.self, from: Data(json.utf8))
    }

    /// 2026-05-30T22:38:55Z built from calendar components, so the expectation does not
    /// lean on the parser under test.
    private func utc(fraction: Double = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 5, day: 30, hour: 22, minute: 38, second: 55))!
        return base.addingTimeInterval(fraction)
    }

    private func call(_ block: DaemonTurnBlock, file: StaticString = #filePath, line: UInt = #line) -> (String, DaemonToolMeta)? {
        guard case let .toolCall(name, _, _, meta) = block else { XCTFail("\(block)", file: file, line: line); return nil }
        return (name, meta)
    }

    private func result(_ block: DaemonTurnBlock, file: StaticString = #filePath, line: UInt = #line) -> (String, Bool, DaemonToolMeta)? {
        guard case let .toolResult(content, isError, meta) = block else { XCTFail("\(block)", file: file, line: line); return nil }
        return (content, isError, meta)
    }

    func testAToolCallCarriesItsIdTargetParentAndTimestamp() throws {
        let block = try decode(#"{"kind":"tool_call","tool_name":"Read","input_summary":"a.swift","input_full":"{}","tool_use_id":"toolu_01","parent_tool_use_id":"toolu_agent1","target":"/repo/a.swift","ts":"2026-05-30T22:38:55.755Z"}"#)
        guard let (name, meta) = call(block) else { return }
        XCTAssertEqual(name, "Read")
        XCTAssertEqual(meta.toolUseId, "toolu_01")
        XCTAssertEqual(meta.parentToolUseId, "toolu_agent1")
        XCTAssertEqual(meta.target, "/repo/a.swift")
        let ts = try XCTUnwrap(meta.ts)
        XCTAssertEqual(ts.timeIntervalSince1970, utc(fraction: 0.755).timeIntervalSince1970, accuracy: 0.001)
    }

    func testAToolResultCarriesItsIdParentAndTimestamp() throws {
        let block = try decode(#"{"kind":"tool_result","content":"","is_error":false,"tool_use_id":"toolu_01","parent_tool_use_id":"toolu_agent1","ts":"2026-05-30T22:38:55.755Z"}"#)
        guard let (content, isError, meta) = result(block) else { return }
        XCTAssertEqual(content, "")
        XCTAssertFalse(isError)
        XCTAssertEqual(meta.toolUseId, "toolu_01")
        XCTAssertEqual(meta.parentToolUseId, "toolu_agent1")
        let ts = try XCTUnwrap(meta.ts)
        XCTAssertEqual(ts.timeIntervalSince1970, utc(fraction: 0.755).timeIntervalSince1970, accuracy: 0.001)
    }

    func testBlocksFromAnOlderDaemonDecodeWithNoMeta() throws {
        let c = try decode(#"{"kind":"tool_call","tool_name":"Bash","input_summary":"ls","input_full":"{}"}"#)
        XCTAssertEqual(call(c)?.1, DaemonToolMeta.none)
        let r = try decode(#"{"kind":"tool_result","content":"boom","is_error":true}"#)
        XCTAssertEqual(result(r)?.2, DaemonToolMeta.none)
        XCTAssertEqual(result(r)?.0, "boom")
    }

    func testTimestampsDecodeWithWholeMillisecondAndNanosecondPrecision() throws {
        func ts(_ raw: String) throws -> Date? {
            result(try decode(#"{"kind":"tool_result","content":"x","is_error":false,"ts":"\#(raw)"}"#))?.2.ts
        }
        let whole = try XCTUnwrap(try ts("2026-05-30T22:38:55Z"))
        XCTAssertEqual(whole.timeIntervalSince1970, utc().timeIntervalSince1970, accuracy: 0.001)
        let millis = try XCTUnwrap(try ts("2026-05-30T22:38:55.755Z"))
        XCTAssertEqual(millis.timeIntervalSince1970, utc(fraction: 0.755).timeIntervalSince1970, accuracy: 0.001)
        let nanos = try XCTUnwrap(try ts("2026-05-30T22:38:55.755123456Z"), "a nanosecond timestamp must not be lost")
        XCTAssertEqual(nanos.timeIntervalSince1970, utc(fraction: 0.755123456).timeIntervalSince1970, accuracy: 0.001)
    }

    func testAnUnparseableTimestampLeavesTheTimeNilAndTheBlockDecoded() throws {
        let block = try decode(#"{"kind":"tool_call","tool_name":"Bash","input_summary":"ls","input_full":"{}","tool_use_id":"toolu_9","ts":"yesterday-ish"}"#)
        guard let (_, meta) = call(block) else { return }
        XCTAssertNil(meta.ts, "a time is decoration: garbage must not cost the client the whole turn")
        XCTAssertEqual(meta.toolUseId, "toolu_9")
    }

    func testTextDecodesWithAndWithoutItsSubagentParent() throws {
        guard case let .text(s, parent) = try decode(#"{"kind":"text","text":"found it","parent_tool_use_id":"toolu_agent1"}"#) else { return XCTFail("subagent text") }
        XCTAssertEqual(s, "found it")
        XCTAssertEqual(parent, "toolu_agent1")
        guard case let .text(_, main) = try decode(#"{"kind":"text","text":"hello"}"#) else { return XCTFail("main text") }
        XCTAssertNil(main)
    }

    func testTheWholeTurnFromAnOlderDaemonStillDecodes() throws {
        let json = #"{"id":"t0","user_input":"hi","timestamp":null,"is_complete":true,"blocks":[{"kind":"text","text":"a"},{"kind":"tool_call","tool_name":"Bash","input_summary":"ls","input_full":"{}"},{"kind":"tool_result","content":"out","is_error":false}]}"#
        let turn = try JSONDecoder().decode(DaemonTurn.self, from: Data(json.utf8))
        XCTAssertEqual(turn.blocks.count, 3)
    }
}

// MARK: - Tool-fold wire enrichment (TF1): folding an empty successful result into its call

final class ToolCompletionFoldingTests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private static let t1 = Date(timeIntervalSince1970: 1_770_000_007)
    private static let t2 = Date(timeIntervalSince1970: 1_770_000_011)

    private func call(_ id: String?, name: String = "Bash") -> TurnBlock {
        .toolCall(ToolCallData(toolName: name, inputSummary: "cmd \(id ?? "?")", inputFull: "{}",
                               toolUseId: id, startedAt: Self.t0))
    }

    private func result(_ id: String?, content: String = "", isError: Bool = false, at: Date? = ToolCompletionFoldingTests.t1) -> TurnBlock {
        .toolResult(ToolResultData(content: content, isError: isError, toolUseId: id, at: at))
    }

    private func callData(_ blocks: [TurnBlock], _ index: Int, file: StaticString = #filePath, line: UInt = #line) -> ToolCallData? {
        guard blocks.indices.contains(index), case .toolCall(let d) = blocks[index] else {
            XCTFail("block \(index) is not a tool call", file: file, line: line); return nil
        }
        return d
    }

    func testAnEmptySuccessfulResultFinishesItsCallAndIsNotAppended() {
        var blocks: [TurnBlock] = [.text("running"), call("toolu_A")]
        let appended = ToolCompletionFolding.apply(result("toolu_A", at: Self.t1), to: &blocks)

        XCTAssertFalse(appended, "an empty success gets no block of its own")
        XCTAssertEqual(blocks.count, 2, "the block array is exactly what it was before the daemon sent empty results")
        XCTAssertEqual(blocks.map(\.kindCode).joined(), "tc")
        let c = callData(blocks, 1)
        XCTAssertEqual(c?.finishedQuietly, true)
        XCTAssertEqual(c?.finishedAt, Self.t1, "the call finished when its result arrived")
        XCTAssertEqual(c?.startedAt, Self.t0, "folding does not disturb the call's start")
        XCTAssertEqual(c?.toolName, "Bash")
        XCTAssertEqual(c?.inputSummary, "cmd toolu_A")
    }

    func testAResultWithContentIsAppendedAndItsCallIsUntouched() {
        var blocks: [TurnBlock] = [call("toolu_A")]
        let appended = ToolCompletionFolding.apply(result("toolu_A", content: "out"), to: &blocks)

        XCTAssertTrue(appended)
        XCTAssertEqual(blocks.map(\.kindCode).joined(), "cr")
        XCTAssertEqual(callData(blocks, 0)?.finishedQuietly, false)
        XCTAssertNil(callData(blocks, 0)?.finishedAt)
        guard case .toolResult(let r) = blocks[1] else { return XCTFail("block 1") }
        XCTAssertEqual(r.content, "out")
        XCTAssertEqual(r.toolUseId, "toolu_A")
        XCTAssertEqual(r.at, Self.t1)
    }

    func testAnErrorWithEmptyContentIsStillAppendedAndItsCallIsUntouched() {
        var blocks: [TurnBlock] = [call("toolu_A")]
        let appended = ToolCompletionFolding.apply(result("toolu_A", content: "", isError: true), to: &blocks)

        XCTAssertTrue(appended, "an error is never quiet: it must show")
        XCTAssertEqual(blocks.map(\.kindCode).joined(), "cr")
        XCTAssertEqual(callData(blocks, 0)?.finishedQuietly, false)
        XCTAssertNil(callData(blocks, 0)?.finishedAt)
        guard case .toolResult(let r) = blocks[1] else { return XCTFail("block 1") }
        XCTAssertTrue(r.isError)
    }

    func testOtherBlocksAreAppendedAsAlways() {
        var blocks: [TurnBlock] = []
        XCTAssertTrue(ToolCompletionFolding.apply(.text("hi"), to: &blocks))
        XCTAssertTrue(ToolCompletionFolding.apply(call("toolu_A"), to: &blocks))
        XCTAssertTrue(ToolCompletionFolding.apply(.note("n"), to: &blocks))
        XCTAssertTrue(ToolCompletionFolding.apply(.errorMessage("e"), to: &blocks))
        XCTAssertEqual(blocks.map(\.kindCode).joined(), "tcne")
    }

    func testTwoParallelCallsWithResultsArrivingOutOfOrderEachFinishTheRightCall() {
        var blocks: [TurnBlock] = [call("toolu_A"), call("toolu_B")]

        XCTAssertFalse(ToolCompletionFolding.apply(result("toolu_B", at: Self.t1), to: &blocks))
        XCTAssertEqual(callData(blocks, 0)?.finishedQuietly, false, "A is still running")
        XCTAssertEqual(callData(blocks, 1)?.finishedQuietly, true)
        XCTAssertEqual(callData(blocks, 1)?.finishedAt, Self.t1)

        XCTAssertFalse(ToolCompletionFolding.apply(result("toolu_A", at: Self.t2), to: &blocks))
        XCTAssertEqual(callData(blocks, 0)?.finishedQuietly, true)
        XCTAssertEqual(callData(blocks, 0)?.finishedAt, Self.t2)
        XCTAssertEqual(callData(blocks, 1)?.finishedAt, Self.t1, "B keeps its own finish time")
        XCTAssertEqual(blocks.count, 2)
    }

    func testAnEmptyResultMatchingNoCallIsDroppedAndNothingIsTouched() {
        var blocks: [TurnBlock] = [call("toolu_A")]
        let appended = ToolCompletionFolding.apply(result("toolu_ZZZ"), to: &blocks)

        XCTAssertFalse(appended, "dropped, exactly as the daemon used to drop it")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(callData(blocks, 0)?.finishedQuietly, false)
        XCTAssertNil(callData(blocks, 0)?.finishedAt)
    }

    func testAnEmptyResultWithNoIdIsDroppedAndNoCallIsTouched() {
        // An id-less call must not be matched by an id-less result either.
        var blocks: [TurnBlock] = [call(nil), call("toolu_A")]
        let appended = ToolCompletionFolding.apply(result(nil), to: &blocks)

        XCTAssertFalse(appended)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(callData(blocks, 0)?.finishedQuietly, false)
        XCTAssertEqual(callData(blocks, 1)?.finishedQuietly, false)
    }

    func testAnEmptyResultOnAnEmptyArrayIsDropped() {
        var blocks: [TurnBlock] = []
        XCTAssertFalse(ToolCompletionFolding.apply(result("toolu_A"), to: &blocks))
        XCTAssertTrue(blocks.isEmpty)
    }

    func testAnEmptyResultDoesNotFinishACallThatIsNotInTheArray() {
        // The call sits in another turn's array: this array has only a different call.
        var blocks: [TurnBlock] = [.text("x"), call("toolu_B")]
        XCTAssertFalse(ToolCompletionFolding.apply(result("toolu_A"), to: &blocks))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(callData(blocks, 1)?.finishedQuietly, false)
    }
}

// MARK: - Tool-fold wire enrichment (TF1): subagent text parents ride beside the blocks

final class ChatTurnSubagentTextParentsTests: XCTestCase {

    func testDroppingLeadingBlocksShiftsEachParentWithItsBlock() {
        var turn = ChatTurn(userInput: "go", timestamp: Date(timeIntervalSince1970: 1_770_000_000),
                            blocks: [.note("model changed"), .text("main"), .text("sub A"), .toolCall(ToolCallData(toolName: "Bash", inputSummary: "ls", inputFull: "{}")), .text("sub B")],
                            subagentTextParents: [2: "toolu_agent1", 4: "toolu_agent2"])

        turn.removeLeadingBlocks(1)

        XCTAssertEqual(turn.blocks.count, 4)
        XCTAssertEqual(turn.subagentTextParents, [1: "toolu_agent1", 3: "toolu_agent2"],
                       "after dropping the leading note, each subagent line must still point at its own text")
        guard case .text(let s) = turn.blocks[1] else { return XCTFail("block 1") }
        XCTAssertEqual(s, "sub A")
    }

    func testDroppingBlocksThatHeldParentsForgetsThoseParents() {
        var turn = ChatTurn(userInput: "go", timestamp: Date(timeIntervalSince1970: 1_770_000_000),
                            blocks: [.text("sub"), .text("main"), .text("sub 2")],
                            subagentTextParents: [0: "toolu_agent1", 2: "toolu_agent2"])
        turn.removeLeadingBlocks(2)
        XCTAssertEqual(turn.subagentTextParents, [0: "toolu_agent2"])
        XCTAssertEqual(turn.blocks.count, 1)
    }

    func testDroppingNoBlocksChangesNothing() {
        var turn = ChatTurn(userInput: "go", timestamp: Date(timeIntervalSince1970: 1_770_000_000),
                            blocks: [.text("a"), .text("b")], subagentTextParents: [1: "toolu_agent1"])
        turn.removeLeadingBlocks(0)
        XCTAssertEqual(turn.blocks.count, 2)
        XCTAssertEqual(turn.subagentTextParents, [1: "toolu_agent1"])
    }
}

// MARK: - Tool-fold wire enrichment (TF1): today's rendering is unchanged

final class ToolFoldRenderingGuardTests: XCTestCase {

    /// `contentKey` keys the virtualizer's height cache; it counts durable block kinds. The
    /// enrichment adds ids, times and parents to blocks and must not change that key.
    func testEnrichedBlocksHaveTheSameContentKeyAsPlainOnes() {
        let when = Date(timeIntervalSince1970: 1_770_000_000)
        func turn(_ blocks: [TurnBlock], parents: [Int: String] = [:]) -> ChatTurn {
            ChatTurn(userInput: "run it", timestamp: when, timestampRaw: "2026-08-11T12:00:00.0000Z",
                     blocks: blocks, isComplete: true, subagentTextParents: parents)
        }
        let plain = turn([.text("hi"),
                          .toolCall(ToolCallData(toolName: "Bash", inputSummary: "ls", inputFull: "{}")),
                          .toolResult(ToolResultData(content: "out", isError: false)),
                          .text("done")])
        let enriched = turn([.text("hi"),
                             .toolCall(ToolCallData(toolName: "Bash", inputSummary: "ls", inputFull: "{}",
                                                    toolUseId: "toolu_1", parentToolUseId: "toolu_agent1",
                                                    target: "/x", startedAt: when, finishedAt: when, finishedQuietly: true)),
                             .toolResult(ToolResultData(content: "out", isError: false, toolUseId: "toolu_1",
                                                        parentToolUseId: "toolu_agent1", at: when)),
                             .text("done")],
                            parents: [3: "toolu_agent1"])
        XCTAssertEqual(enriched.contentKey, plain.contentKey)
        XCTAssertEqual(plain.contentKey.split(separator: "|").last.map(String.init), "tcrt")
    }
}
