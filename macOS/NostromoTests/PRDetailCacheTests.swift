import XCTest

// CiState, CiCheck, PRDetail are compiled into this target directly
// (logic test — no host app, same as PerriModelTests).
//
// RED phase: `PRDetailCache` currently exists only as an empty placeholder
// stub (`struct PRDetailCache {}`) in `Nostromo/Data/PRDetailCache.swift`.
// Every test below is expected to fail to COMPILE — referencing missing
// members (`store`, `detail(forKey:)`, `remove(forKey:)`, `key(repo:number:)`,
// `retainedDiffBytes`, `count`) — until Cody implements the real type. That
// is the correct RED-phase result, not a bug in these tests.

// MARK: - PRDetailCacheTests

/// Behavioural tests for `PRDetailCache`'s LRU eviction policy: bounded
/// primarily by bytes (diffs are unbounded in size), secondarily by entry
/// count, with a `protecting` key that is never evicted.
final class PRDetailCacheTests: XCTestCase {

    // MARK: - Fixture construction

    /// Builds a `PRDetail` whose `diff` is exactly `diffByteCount` UTF-8 bytes
    /// (via a repeated ASCII character, so byte count == character count —
    /// no escaping concerns), decoded the same way production code decodes
    /// `current-pr-detail.json` / per-PR cache files.
    private static func makeDetail(
        repo: String = "acme/web",
        number: Int,
        diffByteCount: Int = 16,
        headSha: String = "sha"
    ) throws -> PRDetail {
        let diff = String(repeating: "x", count: diffByteCount)
        let json = """
        {
            "pr_number": \(number),
            "repo": "\(repo)",
            "title": "pr \(number)",
            "author": "alice",
            "url": "https://github.com/\(repo)/pull/\(number)",
            "diff": "\(diff)",
            "head_sha": "\(headSha)"
        }
        """
        return try JSONDecoder().decode(PRDetail.self, from: json.data(using: .utf8)!)
    }

    // MARK: - 1. Entry cap binds when diffs are small

    /// With small diffs, the entry-count cap is what binds. Storing more
    /// than `maxRetainedEntries` distinct PRs must trim down to exactly the
    /// cap, and it must be the most-recently-stored keys that survive — not
    /// an arbitrary subset.
    func testEntryCapEvictsOldestWhenDiffsAreSmall() throws {
        var cache = PRDetailCache()
        let overflow = 10
        let total = PRDetailCache.maxRetainedEntries + overflow

        for n in 0..<total {
            let detail = try Self.makeDetail(number: n, diffByteCount: 8)
            cache.store(detail, forKey: PRDetailCache.key(repo: "acme/web", number: n), protecting: nil)
        }

        XCTAssertEqual(cache.count, PRDetailCache.maxRetainedEntries, """
            Storing maxRetainedEntries + \(overflow) small-diff PRs must trim the \
            cache down to exactly the entry cap.
            """)

        // The most-recently-stored `maxRetainedEntries` keys must survive...
        for n in overflow..<total {
            let key = PRDetailCache.key(repo: "acme/web", number: n)
            XCTAssertNotNil(cache.detail(forKey: key), """
                PR #\(n) was among the most recently stored and must still be cached.
                """)
        }
        // ...and the oldest `overflow` keys must have been evicted.
        for n in 0..<overflow {
            let key = PRDetailCache.key(repo: "acme/web", number: n)
            XCTAssertNil(cache.detail(forKey: key), """
                PR #\(n) was among the oldest entries and should have been evicted \
                to make room under the entry cap.
                """)
        }
    }

    // MARK: - 2. Byte budget binds before entry cap

    /// The entry-count cap alone cannot bound this cache, because a single
    /// diff can be arbitrarily large. Storing only a handful of PRs (far
    /// fewer than `maxRetainedEntries`) whose diffs together exceed
    /// `maxRetainedDiffBytes` must still trigger eviction down to the byte
    /// budget. A policy that only counted entries would happily retain all
    /// of these and blow the byte budget — that is exactly the bug this
    /// test guards against.
    func testByteBudgetEvictsWellBeforeEntryCapIsReached() throws {
        var cache = PRDetailCache()

        // Each diff is a third of the byte budget; storing 5 of them (well
        // under maxRetainedEntries) overflows the byte budget more than
        // once over.
        let perDiffBytes = PRDetailCache.maxRetainedDiffBytes / 3
        let numberOfPRs = 5
        XCTAssertLessThan(numberOfPRs, PRDetailCache.maxRetainedEntries, """
            Test setup error: this test must exercise the byte budget while \
            staying well under the entry cap, or it no longer isolates the \
            byte-budget behaviour from the entry-cap behaviour.
            """)

        for n in 0..<numberOfPRs {
            let detail = try Self.makeDetail(number: n, diffByteCount: perDiffBytes)
            cache.store(detail, forKey: PRDetailCache.key(repo: "acme/web", number: n), protecting: nil)
        }

        XCTAssertLessThanOrEqual(cache.retainedDiffBytes, PRDetailCache.maxRetainedDiffBytes, """
            An entry-count-only eviction policy cannot bound this cache, because \
            per-entry diff size is unbounded: 5 large diffs (each ~1/3 of the byte \
            budget) fit easily under maxRetainedEntries (\(PRDetailCache.maxRetainedEntries)) \
            but blow the byte budget several times over. retainedDiffBytes must stay \
            <= maxRetainedDiffBytes even though the entry count is nowhere near its cap.
            """)
        XCTAssertLessThan(cache.count, PRDetailCache.maxRetainedEntries, """
            Sanity check on the test itself: with only \(numberOfPRs) PRs stored, \
            the entry cap was never remotely at risk of binding — so any eviction \
            observed above must have come from the byte budget, not the entry cap.
            """)
    }

    // MARK: - 3. retainedDiffBytes is exact, never drifting

    /// Across a mixed sequence of stores, an overwrite, reads, an explicit
    /// remove, and an eviction, `retainedDiffBytes` must always equal the
    /// exact sum of `diff.utf8.count` over currently-surviving entries — no
    /// silent drift from double-counting on overwrite, forgetting to
    /// subtract on remove, or forgetting to subtract on eviction.
    func testRetainedDiffBytesStaysExactAcrossMixedOperations() throws {
        var cache = PRDetailCache()

        let keyA = PRDetailCache.key(repo: "acme/web", number: 1)
        let keyB = PRDetailCache.key(repo: "acme/web", number: 2)
        let keyC = PRDetailCache.key(repo: "acme/web", number: 3)

        cache.store(try Self.makeDetail(number: 1, diffByteCount: 100), forKey: keyA, protecting: nil)
        cache.store(try Self.makeDetail(number: 2, diffByteCount: 200), forKey: keyB, protecting: nil)
        XCTAssertEqual(cache.retainedDiffBytes, 300)

        // Overwrite A with a different-sized diff: replace, don't accumulate.
        cache.store(try Self.makeDetail(number: 1, diffByteCount: 50), forKey: keyA, protecting: nil)
        XCTAssertEqual(cache.retainedDiffBytes, 250, "Overwriting keyA must replace its byte contribution, not add to it.")

        // A read must not change the byte total.
        _ = cache.detail(forKey: keyB)
        XCTAssertEqual(cache.retainedDiffBytes, 250, "Reading via detail(forKey:) must not change retainedDiffBytes.")

        // Store C, then remove B outright.
        cache.store(try Self.makeDetail(number: 3, diffByteCount: 75), forKey: keyC, protecting: nil)
        XCTAssertEqual(cache.retainedDiffBytes, 325)

        cache.remove(forKey: keyB)
        XCTAssertEqual(cache.retainedDiffBytes, 75 + 50, "remove(forKey:) must free keyB's bytes from the running total.")
        XCTAssertNil(cache.detail(forKey: keyB))

        // Finally, force an eviction and confirm the total still matches the
        // sum over survivors exactly.
        var expectedSurvivingBytes = cache.retainedDiffBytes
        for n in 100..<(100 + PRDetailCache.maxRetainedEntries + 5) {
            let bytes = 8
            cache.store(try Self.makeDetail(number: n, diffByteCount: bytes), forKey: PRDetailCache.key(repo: "acme/web", number: n), protecting: nil)
        }
        // After enough churn, keyA/keyC are almost certainly evicted by the
        // entry cap; regardless of exactly which survive, the invariant
        // must hold: reported total == sum of surviving diffs' byte counts.
        expectedSurvivingBytes = 0
        for n in 100..<(100 + PRDetailCache.maxRetainedEntries + 5) {
            if cache.detail(forKey: PRDetailCache.key(repo: "acme/web", number: n)) != nil {
                expectedSurvivingBytes += 8
            }
        }
        if cache.detail(forKey: keyA) != nil { expectedSurvivingBytes += 50 }
        if cache.detail(forKey: keyC) != nil { expectedSurvivingBytes += 75 }

        XCTAssertEqual(cache.retainedDiffBytes, expectedSurvivingBytes, """
            retainedDiffBytes must always equal the exact sum of diff.utf8.count \
            over currently-surviving entries, with no drift after a mix of stores, \
            an overwrite, reads, a remove, and evictions.
            """)
    }

    // MARK: - 4. LRU is by use, not by insert order

    /// A read via `detail(forKey:)` counts as a use and must update recency
    /// exactly like a write does. Store A, B, C (in that order), then read
    /// A — freshening it — then store enough more entries to force exactly
    /// one eviction. B, not A, must be the one evicted, even though A was
    /// inserted first, because A was the most recently *used* of the two.
    func testLeastRecentlyUsedIsEvictedNotLeastRecentlyInserted() throws {
        var cache = PRDetailCache()

        // Fill the cache to exactly its entry cap with A, B, C, ... so the
        // next store forces exactly one eviction.
        let keyA = PRDetailCache.key(repo: "acme/web", number: 0)
        let keyB = PRDetailCache.key(repo: "acme/web", number: 1)

        for n in 0..<PRDetailCache.maxRetainedEntries {
            cache.store(try Self.makeDetail(number: n, diffByteCount: 8), forKey: PRDetailCache.key(repo: "acme/web", number: n), protecting: nil)
        }
        XCTAssertEqual(cache.count, PRDetailCache.maxRetainedEntries)

        // Touch A via a read, making it the most-recently-used entry. B is
        // now the least-recently-used entry (inserted second, never re-touched).
        XCTAssertNotNil(cache.detail(forKey: keyA))

        // One more store forces exactly one eviction.
        let newKey = PRDetailCache.key(repo: "acme/web", number: 9999)
        cache.store(try Self.makeDetail(number: 9999, diffByteCount: 8), forKey: newKey, protecting: nil)

        XCTAssertNotNil(cache.detail(forKey: keyA), """
            keyA was freshly read (a "use") right before the triggering store, so \
            it must not be the eviction victim even though it was inserted first.
            """)
        XCTAssertNil(cache.detail(forKey: keyB), """
            keyB is the true least-recently-used entry (inserted second, never \
            touched again) and must be the one evicted — LRU tracks last USE, \
            not insertion order.
            """)
    }

    // MARK: - 5. Protected key is never evicted

    /// A `protecting` key passed to `store` must never be the eviction
    /// victim, no matter how stale it is, even when every other signal
    /// (LRU position, insertion order) marks it as the obvious candidate.
    func testProtectedKeyIsNeverEvictedEvenWhenLeastRecentlyUsed() throws {
        var cache = PRDetailCache()
        let protectedKey = PRDetailCache.key(repo: "acme/web", number: 0)

        // Store the protected entry first (making it the stalest by LRU),
        // and keep passing it as `protecting` on every subsequent store so
        // it remains protected throughout.
        cache.store(try Self.makeDetail(number: 0, diffByteCount: 8), forKey: protectedKey, protecting: protectedKey)

        for n in 1...(PRDetailCache.maxRetainedEntries + 10) {
            cache.store(
                try Self.makeDetail(number: n, diffByteCount: 8),
                forKey: PRDetailCache.key(repo: "acme/web", number: n),
                protecting: protectedKey
            )
        }

        XCTAssertNotNil(cache.detail(forKey: protectedKey), """
            The protected key must survive eviction even though it is the \
            least-recently-used entry in the cache — protecting must override LRU.
            """)
    }

    // MARK: - 6. Eviction terminates when only the protected entry remains

    /// If the protected entry alone exceeds the byte budget, eviction of
    /// every other (evictable) entry must still terminate — not hang in a
    /// loop trying to get under budget by evicting an unevictable entry.
    /// The protected entry must survive, and the overage is simply reported
    /// via `retainedDiffBytes` exceeding the budget — that is documented,
    /// expected behaviour here, not a bug.
    func testEvictionTerminatesWhenOnlyProtectedEntryRemainsOverBudget() throws {
        var cache = PRDetailCache()
        let protectedKey = PRDetailCache.key(repo: "acme/web", number: 0)

        // The protected entry's diff alone is bigger than the whole budget.
        let hugeDiffBytes = PRDetailCache.maxRetainedDiffBytes + 1024
        cache.store(
            try Self.makeDetail(number: 0, diffByteCount: hugeDiffBytes),
            forKey: protectedKey,
            protecting: protectedKey
        )

        // Store a handful of other small entries, all protecting the same key.
        for n in 1...5 {
            cache.store(
                try Self.makeDetail(number: n, diffByteCount: 8),
                forKey: PRDetailCache.key(repo: "acme/web", number: n),
                protecting: protectedKey
            )
        }

        // This must return promptly (no hang) and the protected entry must
        // still be present.
        XCTAssertNotNil(cache.detail(forKey: protectedKey), """
            The protected entry must survive even though it alone exceeds the \
            byte budget and there is nothing left to evict but itself.
            """)
        XCTAssertGreaterThan(cache.retainedDiffBytes, PRDetailCache.maxRetainedDiffBytes, """
            When the sole surviving entry is protected and already over budget, \
            the cache must simply report the overage via retainedDiffBytes rather \
            than hide it — this is documented, expected behaviour, not a bug.
            """)
    }

    // MARK: - 7. Oversized entry is refused without disturbing existing entries

    /// An entry whose diff alone exceeds `maxRetainedDiffBytes` must not be
    /// stored at all — protected or not — and, critically, the attempt must
    /// not evict any pre-existing entries on its way to being rejected.
    func testOversizedEntryIsRefusedWithoutEvictingExistingEntries() throws {
        var cache = PRDetailCache()

        let survivorKey = PRDetailCache.key(repo: "acme/web", number: 1)
        cache.store(try Self.makeDetail(number: 1, diffByteCount: 64), forKey: survivorKey, protecting: nil)

        let countBefore = cache.count
        let bytesBefore = cache.retainedDiffBytes

        let oversizedKey = PRDetailCache.key(repo: "acme/web", number: 2)
        let oversized = try Self.makeDetail(number: 2, diffByteCount: PRDetailCache.maxRetainedDiffBytes + 1)
        cache.store(oversized, forKey: oversizedKey, protecting: nil)

        XCTAssertNil(cache.detail(forKey: oversizedKey), """
            An entry whose diff alone exceeds maxRetainedDiffBytes must be refused \
            outright — it must never be stored, since a single such entry could \
            never coexist with the byte budget.
            """)
        XCTAssertEqual(cache.count, countBefore, """
            Rejecting an oversized entry must not evict any pre-existing entries \
            on the way to being rejected.
            """)
        XCTAssertEqual(cache.retainedDiffBytes, bytesBefore, """
            Rejecting an oversized entry must leave retainedDiffBytes unchanged \
            from before the attempted store.
            """)
        XCTAssertNotNil(cache.detail(forKey: survivorKey), """
            The pre-existing entry must still be present after the oversized \
            store attempt was rejected.
            """)
    }

    // MARK: - 8. Overwrite replaces, does not accumulate

    /// Storing the same key twice with different diff sizes must leave
    /// `count == 1` and `retainedDiffBytes` equal to the *second* diff's
    /// byte size — not the sum of both.
    func testOverwritingSameKeyReplacesRatherThanAccumulates() throws {
        var cache = PRDetailCache()
        let key = PRDetailCache.key(repo: "acme/web", number: 1)

        cache.store(try Self.makeDetail(number: 1, diffByteCount: 500), forKey: key, protecting: nil)
        cache.store(try Self.makeDetail(number: 1, diffByteCount: 30), forKey: key, protecting: nil)

        XCTAssertEqual(cache.count, 1, "Overwriting an existing key must not create a second entry.")
        XCTAssertEqual(cache.retainedDiffBytes, 30, """
            retainedDiffBytes after overwriting must equal only the second diff's \
            byte size (30), not the sum of both stores (500 + 30 = 530).
            """)
    }

    // MARK: - 9. remove(forKey:) frees bytes

    /// `remove(forKey:)` must drop a known-stale entry outright, freeing its
    /// byte contribution, and a subsequent read must return nil.
    func testRemoveForKeyFreesBytesAndSubsequentReadReturnsNil() throws {
        var cache = PRDetailCache()
        let key = PRDetailCache.key(repo: "acme/web", number: 1)

        cache.store(try Self.makeDetail(number: 1, diffByteCount: 123), forKey: key, protecting: nil)
        XCTAssertEqual(cache.retainedDiffBytes, 123)

        cache.remove(forKey: key)

        XCTAssertEqual(cache.retainedDiffBytes, 0, "remove(forKey:) must free the removed entry's bytes.")
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.detail(forKey: key), "A removed key must return nil on subsequent lookup.")
    }

    // MARK: - 10. key(repo:number:) stability and documented collision

    func testKeyProducesRepoSlashesAsDashes() {
        XCTAssertEqual(PRDetailCache.key(repo: "acme/web", number: 42), "acme-web-42")
    }

    /// Known, accepted collision risk (documented, not a bug to silently
    /// "fix" here): a repo name that already contains a dash produces the
    /// identical key string as the slash-separated repo name it collides
    /// with. This is inherited/accepted scope — this test documents it as
    /// same-key, not different-key, so nobody "fixes" the collision by
    /// accident via this test suite.
    func testKeyHasDocumentedDashCollisionWithSlashRepoNames() {
        let slashKey = PRDetailCache.key(repo: "acme/web", number: 42)
        let dashKey  = PRDetailCache.key(repo: "acme-web", number: 42)
        XCTAssertEqual(slashKey, dashKey, """
            Known, accepted collision: "acme/web" and "acme-web" both key to \
            "acme-web-42" because '/' is mapped to '-'. This is inherited/accepted \
            scope, not a bug for this test suite to fix — do not change this to \
            assert non-collision.
            """)
    }
}

// MARK: - PRDetailCacheAppStoreWiringTests

/// A fitness function, not a behavioural test — same spirit as
/// `ActivityTickerWiringTests`. It enforces that `AppStore` never bypasses
/// `PRDetailCache`'s own `store`/`remove` API with a direct dictionary
/// subscript write, because that is exactly how the original unbounded-cache
/// bug got in: a raw `prDetailCache[key] = detail` bypasses any eviction
/// policy entirely, no matter how well-designed `PRDetailCache` itself is.
///
/// RED phase: `AppStore.swift` currently still contains
/// `prDetailCache[key] = detail` (two call sites) — Cody has not rewired it
/// to go through `PRDetailCache.store` yet. This test is EXPECTED TO FAIL
/// right now; Cody's rewire step is what makes it pass.
final class PRDetailCacheAppStoreWiringTests: XCTestCase {

    func testAppStoreNeverBypassesCacheWithDirectSubscriptWrite() throws {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/PRDetailCacheTests.swift
            .deletingLastPathComponent()                 // …/macOS/NostromoTests
            .deletingLastPathComponent()                 // …/macOS
            .appendingPathComponent("Nostromo/Data/AppStore.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(source.contains("prDetailCache["), """
            AppStore.swift must never write to prDetailCache via a direct dictionary \
            subscript (prDetailCache[key] = ...) — that bypasses PRDetailCache's own \
            store/remove API entirely, with no eviction policy applied. This exact \
            pattern is how the original unbounded-cache bug got in. All writes must \
            go through PRDetailCache.store(_:forKey:protecting:) instead.
            """)
    }
}
