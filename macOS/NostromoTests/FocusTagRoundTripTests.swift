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
        let json = """
        [
          {
            "id": "legacy-uuid-aaaaaaaa",
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
}
