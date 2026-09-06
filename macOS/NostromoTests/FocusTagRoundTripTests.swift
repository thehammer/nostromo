import XCTest
// Focus and FocusCreatedMeta are compiled into this target directly
// (logic test — no host app, same as SidenavGroupingTests).

// MARK: - FocusTagRoundTripTests

/// Behavioural tests for the tag a focus is addressed by — `Focus.sessionTag`.
///
/// `sessionTag` is the single key the whole system agrees on: the daemon
/// broadcasts pane content and layouts under it, `AppStore` seeds
/// `focusLayouts` / `session(for:)` / per-focus eviction from it, and
/// `FocusStore.wireProjection()` puts it on the wire as `tag` in the focus
/// registry push. So the invariant under test is a round trip: a tag the
/// daemon minted must come back out of this app *unchanged*.
///
/// It did not. `FocusCreatedMeta.toFocus()` stored the wire tag in `id`, and
/// `sessionTag` derived `"\(agentTag)-\(id.prefix(8))"` — a derivation that is
/// only meaningful for a focus this app minted, whose `id` is a UUID. Applied
/// to a tag that is already a tag it mangled it: `cody-core-1234` (agent
/// `cody`) came back out as `cody-cody-cor`. Two failures fell out of that one
/// string: the Mac pushed the phantom into the daemon's registry as a
/// brand-new focus while the real tag never appeared in any push, and every
/// client-side lookup missed the tag the daemon actually broadcasts under, so
/// a daemon-created focus's panes never painted.
final class FocusTagRoundTripTests: XCTestCase {

    /// The tag the daemon hands us in a `focusCreated` event.
    private static let daemonTag = "cody-core-1234"

    /// What the old `id.prefix(8)` derivation produced from that tag. Named
    /// literally so this regression is unmistakable if the derivation ever
    /// comes back: nothing in the system answers to this string.
    private static let mangledTag = "cody-cody-cor"

    /// The `id` a focus *this app* minted has: `CreateFocusSheet` sets
    /// `id: UUID().uuidString`. Being a parseable UUID is the whole
    /// discriminator between an app-minted focus and a daemon-created one
    /// whose `id` is a wire tag — so this constant must stay a real UUID.
    private static let appMintedUUID = "9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90"

    /// The tag `appMintedUUID` derives under agent `claudia`.
    private static let appMintedDerivedTag = "claudia-9F2A4C1E"

    private func daemonCreatedMeta(
        tag: String = FocusTagRoundTripTests.daemonTag,
        agent: String = "cody"
    ) -> FocusCreatedMeta {
        FocusCreatedMeta(
            tag:            tag,
            displayName:    "Cody in Core",
            agentName:      agent,
            projectName:    "core",
            org:            "Carefeed",
            isBuiltIn:      false,
            sessionSummary: nil
        )
    }

    private func appMintedFocus(
        id: String,
        agent: String,
        daemonTag: String? = nil
    ) -> Focus {
        Focus(id: id, agentTag: agent, projectPath: "/Users/hammer/Code/core",
              isBuiltIn: false, org: "Carefeed", daemonTag: daemonTag)
    }

    // MARK: - Test 1: The headline round trip

    func testDaemonCreatedFocus_isAddressedByTheDaemonsOwnTag() {
        let focus = daemonCreatedMeta().toFocus()

        XCTAssertEqual(focus.sessionTag, Self.daemonTag,
                       "a focus the daemon created must be addressed by the tag the daemon "
                       + "broadcasts it under — panes, layouts, sessions and eviction are all "
                       + "keyed on sessionTag")
        XCTAssertNotEqual(focus.sessionTag, Self.mangledTag,
                          "sessionTag must never re-derive a tag that is already a tag: "
                          + "'\(Self.mangledTag)' names no focus on either side of the wire")
    }

    func testDaemonCreatedFocus_recordsTheWireTagAsDaemonTag() {
        let focus = daemonCreatedMeta().toFocus()

        XCTAssertEqual(focus.daemonTag, Self.daemonTag,
                       "toFocus() must record the wire tag in daemonTag — that is the only "
                       + "signal telling sessionTag to skip the app-minted derivation")
        XCTAssertEqual(focus.agentTag, "cody",
                       "agentTag comes from the event's agent_name, not from parsing the tag")
    }

    // MARK: - Test 2: What the registry push puts on the wire

    func testDaemonCreatedFocus_registryPushCarriesTheDaemonsTagBack() {
        let focus = daemonCreatedMeta().toFocus()

        // `FocusStore.wireProjection()` builds each `FocusMetaWire` with
        // `tag: f.sessionTag` — so this property IS the registry-push payload.
        // (Asserted here rather than through `wireProjection()` itself because
        // `FocusStore` is a singleton whose `add`/`save` write the real
        // ~/.nostromo/focuses.json; this stays value-level.)
        let pushedTag = focus.sessionTag

        XCTAssertEqual(pushedTag, Self.daemonTag,
                       "the registry push must return the daemon's own tag; pushing anything "
                       + "else registers a second, phantom focus and leaves the real one absent "
                       + "from every push")
        XCTAssertNotEqual(pushedTag, Self.mangledTag,
                          "pushing '\(Self.mangledTag)' is how the phantom focus got into the "
                          + "daemon's registry in the first place")
    }

    // MARK: - Test 3: App-minted focuses still derive their tag

    func testAppMintedDynamicFocus_derivesTagFromAgentAndIdPrefix() {
        let uuid  = "9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90"
        let focus = appMintedFocus(id: uuid, agent: "claudia")

        XCTAssertNil(focus.daemonTag,
                     "a focus this app minted has no daemon tag — the daemon learns it from us")
        XCTAssertEqual(focus.sessionTag, "claudia-9F2A4C1E",
                       "an app-minted focus (UUID id) must keep deriving "
                       + "'agentTag-id.prefix(8)' — this is the overwhelming majority of focuses "
                       + "and every one of their saved layouts is keyed on it")
    }

    func testBuiltInFocus_isAddressedByItsAgentTag() {
        for builtIn in Focus.builtIns {
            XCTAssertNil(builtIn.daemonTag,
                         "built-in \(builtIn.id) is minted by this app, not the daemon")
            XCTAssertEqual(builtIn.sessionTag, builtIn.agentTag,
                           "built-in '\(builtIn.id)' must stay addressable as its bare agent tag")
        }
    }

    // MARK: - Test 4: Codable is additive

    func testDecode_focusSavedBeforeDaemonTagExisted_stillDecodes() throws {
        // A focuses.json entry written before `daemonTag` existed: the key is
        // absent entirely. `Focus.init(from:)` is hand-written precisely
        // because a missing key once failed the whole saved focus list, not
        // just the one field.
        let json = """
        {
          "id": "9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90",
          "agentTag": "claudia",
          "projectPath": "/Users/hammer/Code/core",
          "isBuiltIn": false,
          "org": "Carefeed"
        }
        """
        let focus = try JSONDecoder().decode(Focus.self, from: Data(json.utf8))

        XCTAssertNil(focus.daemonTag,
                     "a missing 'daemonTag' key must decode as nil, not throw — throwing takes "
                     + "the entire saved focus list down with it")
        XCTAssertEqual(focus.sessionTag, "claudia-9F2A4C1E",
                       "a focus saved before daemonTag existed must keep exactly the tag it had")
    }

    func testDecode_focusListSurvivesOneEntryPredatingDaemonTag() throws {
        // The failure mode that made `init(from:)` hand-written is a LIST
        // decode: one legacy entry must not take its neighbours with it.
        //
        // The first entry's `id` must be a REAL UUID, because that is what a
        // pre-daemonTag *app-minted* focus actually has on disk
        // (`CreateFocusSheet` sets `id: UUID().uuidString`). The fixture
        // previously used the hand-written string "legacy-uuid-aaaaaaaa",
        // which no producer of a `Focus` has ever written, and which the f15
        // self-healing migration correctly reads as a daemon wire tag. Using a
        // real UUID keeps this test testing what it means to test — that one
        // legacy entry does not take its neighbours down with it — and leaves
        // the migration itself to the tests below.
        let json = """
        [
          {
            "id": "B1C2D3E4-5F60-4718-9A2B-3C4D5E6F7A8B",
            "agentTag": "cody",
            "isBuiltIn": false
          },
          {
            "id": "cody-core-1234",
            "agentTag": "cody",
            "isBuiltIn": false,
            "daemonTag": "cody-core-1234"
          }
        ]
        """
        let focuses = try JSONDecoder().decode([Focus].self, from: Data(json.utf8))

        XCTAssertEqual(focuses.count, 2,
                       "a saved list mixing pre- and post-daemonTag entries must decode whole")
        XCTAssertNil(focuses[0].daemonTag)
        XCTAssertEqual(focuses[1].daemonTag, Self.daemonTag,
                       "a persisted daemon-created focus must reload still addressable by the "
                       + "daemon's tag")
        XCTAssertEqual(focuses[1].sessionTag, Self.daemonTag)
    }

    func testEncodeDecodeRoundTrip_preservesDaemonTag() throws {
        let original = daemonCreatedMeta().toFocus()

        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Focus.self, from: data)

        XCTAssertEqual(decoded.daemonTag, Self.daemonTag,
                       "daemonTag must survive the save/reload cycle — otherwise a restart "
                       + "re-mangles the tag and the focus's panes stop painting again")
        XCTAssertEqual(decoded.sessionTag, original.sessionTag,
                       "a focus must be addressed by the same tag before and after persistence")
        XCTAssertNotEqual(decoded.sessionTag, Self.mangledTag)
    }

    // MARK: - Test 5: An empty daemon tag is not a tag

    func testEmptyDaemonTag_fallsBackToTheDerivedTag() {
        let uuid  = "9F2A4C1E-8B3D-4A76-9C21-0D5E6F7A8B90"
        let focus = appMintedFocus(id: uuid, agent: "claudia", daemonTag: "")

        XCTAssertEqual(focus.sessionTag, "claudia-9F2A4C1E",
                       "an empty daemonTag names nothing; sessionTag must fall back to the "
                       + "derivation rather than addressing the focus by the empty string")
        XCTAssertFalse(focus.sessionTag.isEmpty,
                       "no focus may ever have an empty sessionTag — an empty registry-push tag "
                       + "would collide with every other empty-tagged focus on the daemon")
    }

    // MARK: - Test 6: A legacy daemon-created focus heals itself on decode (f15)
    //
    // `daemonTag` was additive, so every daemon-created focus persisted before
    // it existed is on disk with `daemonTag` absent and the daemon's wire tag
    // sitting in `id` (that is where `FocusMetaWire.toFocus()` put it). Such an
    // entry re-derives the mangled tag on every launch, so `focusLayouts` never
    // has an entry under the tag the daemon broadcasts, the focus renders
    // `FocusLayoutModel.initial` forever, and no pane content ever reaches the
    // screen — permanently, until the user deletes and recreates the focus.
    //
    // The fix is a decode-time backfill, gated on three clauses that each
    // protect a healthy focus from being silently re-keyed:
    //   daemonTag == nil          — leave already-migrated/new focuses alone
    //   !isBuiltIn                — built-in ids were never wire tags
    //   UUID(uuidString: id) == nil — a non-UUID id can only be a wire tag
    // `id` is never rewritten in any branch.

    /// A `focuses.json` entry for a daemon-created focus, written before
    /// `daemonTag` existed: the wire tag is in `id` and the key is absent.
    private func legacyDaemonCreatedJSON(
        id: String = FocusTagRoundTripTests.daemonTag,
        agent: String = "cody"
    ) -> String {
        """
        {
          "id": "\(id)",
          "agentTag": "\(agent)",
          "projectPath": "/Users/hammer/Code/core",
          "isBuiltIn": false,
          "org": "Carefeed"
        }
        """
    }

    /// A `focuses.json` entry for a focus this app minted: UUID `id`, no
    /// `daemonTag`.
    private func appMintedJSON(
        id: String = FocusTagRoundTripTests.appMintedUUID,
        agent: String = "claudia"
    ) -> String {
        """
        {
          "id": "\(id)",
          "agentTag": "\(agent)",
          "projectPath": "/Users/hammer/Code/core",
          "isBuiltIn": false,
          "org": "Carefeed"
        }
        """
    }

    /// A `focuses.json` entry for a built-in focus. Built-in ids ("perri",
    /// "fred", …) are all non-UUID, so the `!isBuiltIn` clause is the *only*
    /// thing standing between them and the backfill.
    private func builtInJSON(id: String) -> String {
        """
        {
          "id": "\(id)",
          "agentTag": "\(id)",
          "isBuiltIn": true,
          "org": "Carefeed"
        }
        """
    }

    /// A `focuses.json` entry for a daemon-created focus that already carries
    /// `daemonTag` — either written by a current build, or written by a
    /// previous launch after the backfill ran.
    private func migratedDaemonJSON(
        id: String = FocusTagRoundTripTests.daemonTag,
        agent: String = "cody"
    ) -> String {
        """
        {
          "id": "\(id)",
          "agentTag": "\(agent)",
          "projectPath": "/Users/hammer/Code/core",
          "isBuiltIn": false,
          "org": "Carefeed",
          "daemonTag": "\(id)"
        }
        """
    }

    private func decodeFocus(_ json: String) throws -> Focus {
        try JSONDecoder().decode(Focus.self, from: Data(json.utf8))
    }

    // MARK: 6a — the migration fires

    func testDecode_legacyDaemonCreatedFocus_healsItsOwnTag() throws {
        let focus = try decodeFocus(legacyDaemonCreatedJSON())

        XCTAssertEqual(focus.daemonTag, Self.daemonTag,
                       "a persisted daemon-created focus with no daemonTag and a non-UUID id "
                       + "can only have got that id from the daemon; decode must backfill "
                       + "daemonTag from it, because nothing else will ever supply it and the "
                       + "focus is otherwise unfixable without deleting and recreating it")
        XCTAssertEqual(focus.sessionTag, Self.daemonTag,
                       "after backfill the focus must be addressed by the daemon's own tag — "
                       + "that is the key focusLayouts, session(for:) and pane content are all "
                       + "broadcast under; miss it and the focus renders "
                       + "FocusLayoutModel.initial forever and never paints a pane")
        XCTAssertNotEqual(focus.sessionTag, Self.mangledTag,
                          "reloading must not resurrect '\(Self.mangledTag)' — the re-derived "
                          + "tag that names no focus on either side of the wire")
    }

    // MARK: 6b — the migration does NOT fire (clause guards)

    func testDecode_appMintedFocus_keepsItsDerivedTagAndNoDaemonTag() throws {
        // Guards the `UUID(uuidString: id) == nil` clause. Highest-stakes
        // negative in the suite: app-minted focuses are the overwhelming
        // majority, and re-keying one orphans every layout it ever saved.
        XCTAssertNotNil(UUID(uuidString: Self.appMintedUUID),
                        "fixture precondition: an app-minted id must be a parseable UUID, "
                        + "otherwise this test is not exercising the clause it claims to")

        let focus = try decodeFocus(appMintedJSON())

        XCTAssertNil(focus.daemonTag,
                     "a focus this app minted has no daemon tag and must not be given one: "
                     + "writing its UUID id into daemonTag re-keys the focus away from "
                     + "'\(Self.appMintedDerivedTag)' and orphans all of its saved layouts")
        XCTAssertEqual(focus.sessionTag, Self.appMintedDerivedTag,
                       "an app-minted focus must keep deriving 'agentTag-id.prefix(8)' across "
                       + "the migration — this is the status quo for nearly every focus on disk")
    }

    func testDecode_builtInFocus_isNeverMigratedDespiteItsNonUUIDId() throws {
        // Guards the `!isBuiltIn` clause. Every built-in id is a non-UUID
        // string, so without that clause all four would be backfilled.
        //
        // Note the daemonTag-is-nil assertion is the load-bearing one here: a
        // built-in's `id` equals its `agentTag`, so backfilling would leave
        // `sessionTag` looking correct while quietly inventing a daemon origin
        // the focus never had — and with it a claim that the daemon, not this
        // app, owns the tag.
        for id in ["perri", "fred", "mother", "teri"] {
            XCTAssertNil(UUID(uuidString: id),
                         "fixture precondition: built-in id '\(id)' must be non-UUID, which is "
                         + "exactly why only the isBuiltIn clause protects it")

            let focus = try decodeFocus(builtInJSON(id: id))

            XCTAssertNil(focus.daemonTag,
                         "built-in '\(id)' is minted by this app and never had a wire tag in "
                         + "its id; backfilling daemonTag here would invent a daemon origin "
                         + "the focus never had")
            XCTAssertEqual(focus.sessionTag, focus.agentTag,
                           "built-in '\(id)' must stay addressable as its bare agent tag — the "
                           + "daemon has broadcast under that tag since before focuses had ids")
        }
    }

    func testDecode_alreadyMigratedFocus_isUntouchedAndReDecodesIdentically() throws {
        // Guards the `daemonTag == nil` clause, and pins the idempotence the
        // design rests on: the migration is self-persisting (the next
        // FocusStore.save() writes daemonTag through) and carries no migration
        // flag or schema version, so re-running it on already-migrated data
        // must be a no-op forever.
        let first = try decodeFocus(migratedDaemonJSON())

        XCTAssertEqual(first.daemonTag, Self.daemonTag,
                       "an entry that already carries daemonTag must be left exactly as saved")
        XCTAssertEqual(first.sessionTag, Self.daemonTag,
                       "and must stay addressed by the daemon's tag")

        let second = try decodeFocus(String(decoding: try JSONEncoder().encode(first),
                                            as: UTF8.self))

        XCTAssertEqual(second.daemonTag, first.daemonTag,
                       "save-and-reload must not change daemonTag a second time; a migration "
                       + "that is not idempotent needs a flag, and this one deliberately has none")
        XCTAssertEqual(second.sessionTag, first.sessionTag,
                       "a focus must be addressed by the same tag on every launch, not drift "
                       + "one derivation further on each reload")
    }

    func testDecode_healedLegacyFocus_survivesSaveAndReloadUnchanged() throws {
        // The other half of the idempotence claim: the backfill is
        // self-persisting. Once it has run, the next FocusStore.save() writes
        // daemonTag through, and the reloaded focus must be byte-for-byte
        // stable rather than shifting tag again on the second pass.
        let healed = try decodeFocus(legacyDaemonCreatedJSON())

        let reloaded = try decodeFocus(String(decoding: try JSONEncoder().encode(healed),
                                              as: UTF8.self))

        XCTAssertEqual(reloaded.daemonTag, healed.daemonTag,
                       "the backfilled daemonTag must survive the save/reload cycle — that is "
                       + "what makes a migration flag and a schema version bump unnecessary")
        XCTAssertEqual(reloaded.sessionTag, healed.sessionTag,
                       "and the focus must be addressed by the same tag before and after "
                       + "persistence, not drift on each launch")
        XCTAssertEqual(reloaded.sessionTag, Self.daemonTag,
                       "the stable value must be the daemon's own tag")
        XCTAssertNotEqual(reloaded.sessionTag, Self.mangledTag,
                          "and never '\(Self.mangledTag)'")
    }

    func testDecode_anExplicitDaemonTagIsAuthoritative_andSurvivesTheBackfill() throws {
        // The real guard on the `daemonTag == nil` clause.
        //
        // `testDecode_alreadyMigratedFocus_...` above cannot catch that clause
        // being dropped: `FocusMetaWire.toFocus()` writes the wire tag into
        // BOTH `id` and `daemonTag`, so on any entry it produced `daemonTag = id`
        // is a no-op and an unguarded backfill looks harmless.
        //
        // The clause earns its keep the moment the two diverge — which
        // `focuses.json` permits and `Focus.daemonTag` being a `var` invites:
        // any future code path that re-tags a focus (a daemon-side rename, a
        // moved session) updates `daemonTag` and deliberately leaves `id`
        // alone, because `id` is identity. An unguarded backfill would then
        // silently revert that on the very next launch and re-key the focus to
        // a tag the daemon has stopped broadcasting under. So the invariant is
        // stated directly: a persisted `daemonTag` is authoritative, and decode
        // must never overwrite it with anything it could derive from `id`.
        let json = """
        {
          "id": "\(Self.daemonTag)",
          "agentTag": "cody",
          "isBuiltIn": false,
          "org": "Carefeed",
          "daemonTag": "cody-core-5678"
        }
        """
        let focus = try decodeFocus(json)

        XCTAssertEqual(focus.daemonTag, "cody-core-5678",
                       "a daemonTag that was explicitly saved must come back exactly as saved; "
                       + "the id backfill is a repair for entries that have NO daemonTag, not a "
                       + "recomputation that overrides one the app was told")
        XCTAssertEqual(focus.sessionTag, "cody-core-5678",
                       "and the focus must be addressed by that saved tag — reverting it to the "
                       + "one embedded in `id` points every lookup at a tag the daemon is no "
                       + "longer broadcasting under")
        XCTAssertNotEqual(focus.daemonTag, focus.id,
                          "fixture precondition: this test is only meaningful while daemonTag "
                          + "and id differ — that divergence is what makes the "
                          + "`daemonTag == nil` clause detectable at all")
    }

    // MARK: 6c — id is identity, in every branch

    func testDecode_neverRewritesId_inAnyMigrationBranch() throws {
        let cases: [(label: String, json: String, expectedID: String)] = [
            ("legacy daemon-created (backfilled)", legacyDaemonCreatedJSON(), Self.daemonTag),
            ("app-minted (untouched)",             appMintedJSON(),           Self.appMintedUUID),
            ("built-in (untouched)",               builtInJSON(id: "perri"),  "perri"),
            ("already migrated (untouched)",       migratedDaemonJSON(),      Self.daemonTag),
        ]

        for c in cases {
            let focus = try decodeFocus(c.json)

            XCTAssertEqual(focus.id, c.expectedID,
                           "\(c.label): decode must never rewrite `id`. `id` is the focus's "
                           + "identity for every consumer that is not sessionTag — selection, "
                           + "the sidebar, deletion, saved per-focus client state. Only "
                           + "daemonTag is backfilled. Rewriting `id` would re-key client-side "
                           + "state, which is the exact failure this migration exists to end, "
                           + "not to repeat.")
        }
    }

    // MARK: 6d — a mixed saved list

    func testDecode_focusListHealsOnlyTheLegacyDaemonEntry() throws {
        // The companion to `testDecode_focusListSurvivesOneEntryPredatingDaemonTag`:
        // there the legacy entry is app-minted and must NOT be migrated; here it
        // is daemon-created and MUST be, without disturbing its neighbour. Both
        // intents are load-bearing, so both are covered.
        let json = """
        [
          {
            "id": "\(Self.daemonTag)",
            "agentTag": "cody",
            "isBuiltIn": false
          },
          {
            "id": "\(Self.appMintedUUID)",
            "agentTag": "claudia",
            "isBuiltIn": false
          }
        ]
        """
        let focuses = try JSONDecoder().decode([Focus].self, from: Data(json.utf8))

        XCTAssertEqual(focuses.count, 2,
                       "a saved list mixing a legacy daemon-created focus with an app-minted "
                       + "one must decode whole")
        XCTAssertEqual(focuses[0].daemonTag, Self.daemonTag,
                       "the legacy daemon-created entry must be healed in a list decode too — "
                       + "a list decode is the only way focuses.json is ever read")
        XCTAssertEqual(focuses[0].sessionTag, Self.daemonTag,
                       "and must come out addressed by the daemon's own tag")
        XCTAssertNil(focuses[1].daemonTag,
                     "healing one entry must not touch its neighbours: the app-minted focus "
                     + "beside it still has no daemon tag")
        XCTAssertEqual(focuses[1].sessionTag, Self.appMintedDerivedTag,
                       "and still derives exactly the tag its saved layouts are keyed on")
    }
}
