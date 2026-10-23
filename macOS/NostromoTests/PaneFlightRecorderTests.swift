import XCTest

// The per-pane flight recorder: a small, bounded, content-free ring of "what the pane just did"
// (numbers and fixed names only), cheap enough to leave on in production, so that when a pane
// goes blank the capture can say what happened in the seconds before. These tests describe it
// from outside: what it keeps, in what order, what its JSON looks like, and what it costs.
final class PaneFlightRecorderTests: XCTestCase {

    // MARK: - Bounded and ordered

    func testTheRingNeverHoldsMoreThanItsCapacityAndKeepsTheNewestInOrder() {
        let recorder = PaneFlightRecorder()
        XCTAssertEqual(recorder.capacity, PaneFlightRecorder.defaultCapacity)
        XCTAssertEqual(PaneFlightRecorder.defaultCapacity, 200)

        for i in 0 ..< 1000 {
            recorder.record(.scroll, Double(i))
        }

        XCTAssertEqual(recorder.count, 200, "the ring is full and no bigger than its capacity")
        XCTAssertEqual(recorder.totalRecorded, 1000, "the total counts every event ever appended, kept or not")

        let events = recorder.events
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(events.map(\.a), (800 ..< 1000).map(Double.init),
                       "the oldest events were dropped; what is left is the newest 200, oldest first")
        for (older, newer) in zip(events, events.dropFirst()) {
            XCTAssertLessThan(older.seq, newer.seq, "sequence numbers strictly increase from oldest to newest")
            XCTAssertLessThanOrEqual(older.uptimeNs, newer.uptimeNs, "time never runs backwards along the ring")
        }
        XCTAssertEqual(events.last!.seq - events.first!.seq, 199, "no event was skipped inside the kept window")
    }

    func testARingBelowCapacityReportsExactlyWhatWasRecorded() {
        let recorder = PaneFlightRecorder(capacity: 10)
        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(recorder.totalRecorded, 0)
        XCTAssertTrue(recorder.events.isEmpty)

        recorder.record(.layout)
        recorder.record(.docHeight, 1, 2, 3, 4)
        recorder.record(.draw, reason: .scroll)

        XCTAssertEqual(recorder.count, 3)
        XCTAssertEqual(recorder.totalRecorded, 3)
        XCTAssertEqual(recorder.events.map(\.kind), [.layout, .docHeight, .draw])
        XCTAssertEqual(recorder.events[1].a, 1)
        XCTAssertEqual(recorder.events[1].b, 2)
        XCTAssertEqual(recorder.events[1].c, 3)
        XCTAssertEqual(recorder.events[1].d, 4)
        XCTAssertEqual(recorder.events[2].reason, .scroll)
        XCTAssertEqual(recorder.events[0].reason, .none, "no reason given means no reason")
    }

    func testASmallCapacityIsHonoured() {
        let recorder = PaneFlightRecorder(capacity: 5)
        for i in 0 ..< 12 { recorder.record(.layout, Double(i)) }
        XCTAssertEqual(recorder.capacity, 5)
        XCTAssertEqual(recorder.count, 5)
        XCTAssertEqual(recorder.events.map(\.a), [7, 8, 9, 10, 11])
        XCTAssertEqual(recorder.totalRecorded, 12)
    }

    // MARK: - Coalescing

    /// A burst (scroll ticks, layout passes) must not wash the ring: inside the interval it
    /// updates the newest event of that kind instead of appending.
    func testACoalescedEventWithinTheIntervalUpdatesTheNewestOneInPlace() {
        let recorder = PaneFlightRecorder(capacity: 10)
        recorder.recordCoalesced(.scroll, minIntervalMs: 60_000, 1, 1, 1, 1)
        let first = recorder.events.last!

        recorder.recordCoalesced(.scroll, minIntervalMs: 60_000, 9, 8, 7, 6)
        recorder.recordCoalesced(.scroll, minIntervalMs: 60_000, 5, 5, 5, 5)

        XCTAssertEqual(recorder.count, 1, "a burst is one event")
        XCTAssertEqual(recorder.totalRecorded, 1, "a coalesced update is not a new event")
        let event = recorder.events.last!
        XCTAssertEqual(event.seq, first.seq, "it is the same event, updated")
        XCTAssertEqual(event.uptimeNs, first.uptimeNs, "the event keeps the time it first happened")
        XCTAssertEqual([event.a, event.b, event.c, event.d], [5, 5, 5, 5], "the payload is the latest one")
        XCTAssertEqual(event.coalescedCount, 3, "and it remembers how many updates it stands for")
    }

    func testACoalescedEventAfterTheIntervalAppendsANewOne() {
        let recorder = PaneFlightRecorder(capacity: 10)
        recorder.recordCoalesced(.scroll, minIntervalMs: 10, 1)
        Thread.sleep(forTimeInterval: 0.05)   // 50 ms, well past the 10 ms interval
        recorder.recordCoalesced(.scroll, minIntervalMs: 10, 2)

        XCTAssertEqual(recorder.count, 2)
        XCTAssertEqual(recorder.totalRecorded, 2)
        XCTAssertEqual(recorder.events.map(\.a), [1, 2])
        XCTAssertEqual(recorder.events.last!.coalescedCount, 1)
    }

    func testACoalescedEventWithNothingOfItsKindBeforeItAppends() {
        let recorder = PaneFlightRecorder(capacity: 10)
        recorder.record(.layout, 1)
        recorder.recordCoalesced(.scroll, minIntervalMs: 60_000, 2)
        XCTAssertEqual(recorder.count, 2)
        XCTAssertEqual(recorder.events.map(\.kind), [.layout, .scroll])
    }

    func testAZeroIntervalNeverCoalesces() {
        let recorder = PaneFlightRecorder(capacity: 10)
        recorder.recordCoalesced(.scroll, minIntervalMs: 0, 1)
        recorder.recordCoalesced(.scroll, minIntervalMs: 0, 2)
        XCTAssertEqual(recorder.count, 2)
    }

    // MARK: - JSON shape

    func testEventDictionariesAreJSONReadyOldestFirstWithNamedFields() throws {
        let recorder = PaneFlightRecorder(capacity: 10)
        recorder.record(.viewsMaterialized, 1, 2, 3, 4)
        recorder.record(.docHeight, reason: .resize, 1, 2, 3, 4)
        recorder.recordCoalesced(.scroll, minIntervalMs: 60_000, 1, 2, 3, 4)
        recorder.recordCoalesced(.scroll, minIntervalMs: 60_000, 1, 2, 3, 4)

        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z
        let dicts = recorder.eventDictionaries(now: now)

        XCTAssertTrue(JSONSerialization.isValidJSONObject(dicts), "the ring has to be writable as JSON as it is")
        XCTAssertEqual(dicts.count, 3)
        XCTAssertEqual(dicts.map { $0["kind"] as? String }, ["viewsMaterialized", "docHeight", "scroll"],
                       "the kind is the case's own name, oldest first")

        var lastSeq = -1.0
        var lastT = -1.0
        for dict in dicts {
            let seq = try XCTUnwrap((dict["seq"] as? NSNumber)?.doubleValue, "every event has a seq")
            let t = try XCTUnwrap((dict["tMs"] as? NSNumber)?.doubleValue, "every event has an uptime in ms")
            XCTAssertGreaterThan(seq, lastSeq)
            XCTAssertGreaterThanOrEqual(t, lastT)
            lastSeq = seq
            lastT = t
            let wall = try XCTUnwrap(dict["wall"] as? String, "every event has an ISO8601 wall time")
            XCTAssertTrue(wall.hasPrefix("2027-01-15T"), "wall time is derived from `now`: \(wall)")
            XCTAssertTrue(wall.hasSuffix("Z"), "wall time is UTC: \(wall)")
        }

        XCTAssertNil(dicts[0]["reason"], "no reason key when the reason is none")
        XCTAssertEqual(dicts[1]["reason"] as? String, PaneFlightRecorder.Reason.resize.name)
        XCTAssertNil(dicts[0]["n"], "no coalesce count on a plain event")
        XCTAssertEqual((dicts[2]["n"] as? NSNumber)?.intValue, 2, "a coalesced event says how many it stands for")

        // One key per field name, carrying the numeric payload in order.
        for (dict, kind) in zip(dicts, [PaneFlightRecorder.Kind.viewsMaterialized, .docHeight, .scroll]) {
            for (index, name) in kind.fieldNames.enumerated() {
                let value = try XCTUnwrap((dict[name] as? NSNumber)?.doubleValue,
                                          "\(kind.name) is missing its '\(name)' field")
                XCTAssertEqual(value, Double(index + 1), "\(kind.name).\(name) carries payload slot \(index + 1)")
            }
        }
    }

    /// The recorder is content-free by construction: apart from fixed vocabulary, no string
    /// can be in an event.
    func testEventDictionariesContainNoFreeFormStrings() {
        let recorder = PaneFlightRecorder(capacity: 64)
        for kind in PaneFlightRecorder.Kind.allCases {
            recorder.record(kind, reason: .test, 11, 22, 33, 44)
        }
        let allowedStrings = Set(PaneFlightRecorder.Kind.allCases.map(\.name) + [
            PaneFlightRecorder.Reason.test.name
        ])
        var reservedKeys: Set<String> = ["seq", "kind", "tMs", "wall", "reason", "n"]
        for kind in PaneFlightRecorder.Kind.allCases { reservedKeys.formUnion(kind.fieldNames) }

        for dict in recorder.eventDictionaries(now: Date()) {
            for (key, value) in dict {
                XCTAssertTrue(reservedKeys.contains(key), "unexpected key '\(key)'")
                if let string = value as? String {
                    XCTAssertTrue(key == "wall" || allowedStrings.contains(string),
                                  "'\(key)' holds a free-form string: \(string)")
                }
            }
        }
    }

    func testEveryKindHasItsOwnNameAndAtMostFourDistinctFieldNames() {
        var names = Set<String>()
        for kind in PaneFlightRecorder.Kind.allCases {
            XCTAssertEqual(kind.name, String(describing: kind))
            XCTAssertTrue(names.insert(kind.name).inserted, "two kinds share the name \(kind.name)")
            XCTAssertLessThanOrEqual(kind.fieldNames.count, 4, "\(kind.name) has more than four payload slots")
            XCTAssertEqual(Set(kind.fieldNames).count, kind.fieldNames.count, "\(kind.name) repeats a field name")
            for reserved in ["seq", "kind", "tMs", "wall", "reason", "n"] {
                XCTAssertFalse(kind.fieldNames.contains(reserved), "\(kind.name) shadows the '\(reserved)' key")
            }
        }
        XCTAssertEqual(PaneFlightRecorder.Kind.allCases.count, 21)
    }

    // MARK: - Overhead budget

    /// The recorder is always on, in every pane, on the main thread. Recording must stay in the
    /// low microseconds so it can never be the reason a pane stalls. The bound is deliberately
    /// generous (5 us average) so a loaded CI machine does not flake it.
    func testRecordingStaysWithinTheOverheadBudget() {
        let recorder = PaneFlightRecorder()
        let iterations = 100_000

        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0 ..< iterations {
            recorder.record(.scroll, reason: .scroll, Double(i), 1, 2, 3)
        }
        let elapsedNs = Double(DispatchTime.now().uptimeNanoseconds - start)

        let averageMicroseconds = elapsedNs / Double(iterations) / 1_000
        XCTAssertLessThan(averageMicroseconds, 5, "average \(averageMicroseconds) us per record")
        XCTAssertLessThan(elapsedNs / 1_000_000_000, 2, "100k records took longer than 2 s")
        XCTAssertEqual(recorder.count, recorder.capacity, "memory stays bounded however many are recorded")
        XCTAssertEqual(recorder.totalRecorded, UInt64(iterations))
    }
}
