// NostromoKit — SlashCommandWireTests.swift
//
// `session_commands_get` (client) and `session_commands` (server):
//   {"type":"session_commands","request_id":…,"tag":…,"source":"cli"|"init"|"none",
//    "commands":[{name,description?,argument_hint?,aliases?,builtin?}]}
//
// Entries decode leniently: a bad entry is skipped, unknown fields are ignored, a missing optional
// field is nil/empty/false. `SlashCommandCatalog` merges what the daemon reported with the built-in
// fallback table.

import XCTest
@testable import NostromoKit

final class SlashCommandWireTests: XCTestCase {

    // MARK: - Helpers

    private func decodeFrame(_ json: String) -> ServerMsg {
        ServerMsg.decode(from: Data(json.utf8))
    }

    private func sessionCommands(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> SessionCommandsWire? {
        guard case .sessionCommands(let wire) = decodeFrame(json) else {
            XCTFail("not a session_commands frame", file: file, line: line)
            return nil
        }
        return wire
    }

    private func entry(_ json: String) throws -> SlashCommandEntryWire {
        try JSONDecoder().decode(SlashCommandEntryWire.self, from: Data(json.utf8))
    }

    // MARK: - session_commands_get

    func testSessionCommandsGetEncodesExactlyItsThreeKeys() throws {
        let data = try JSONEncoder().encode(ClientSessionCommandsGet(requestId: "req-9", tag: "cody-1"))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(dict.keys), ["type", "request_id", "tag"])
        XCTAssertEqual(dict["type"] as? String, "session_commands_get")
        XCTAssertEqual(dict["request_id"] as? String, "req-9")
        XCTAssertEqual(dict["tag"] as? String, "cody-1")
    }

    // MARK: - session_commands through the public decoder

    func testAFullSessionCommandsFrameDecodesFieldForField() throws {
        let wire = try XCTUnwrap(sessionCommands(#"""
        {"type":"session_commands","request_id":"req-1","tag":"cody-1","source":"cli","commands":[
          {"name":"context","description":"Show current context usage","argument_hint":"[detail]",
           "aliases":["ctx"],"builtin":true},
          {"name":"hookify:list"}
        ]}
        """#))

        XCTAssertEqual(wire.requestId, "req-1")
        XCTAssertEqual(wire.tag, "cody-1")
        XCTAssertEqual(wire.source, "cli")
        XCTAssertEqual(wire.commands, [
            SlashCommandEntryWire(name: "context", description: "Show current context usage",
                                  argumentHint: "[detail]", aliases: ["ctx"], builtin: true),
            SlashCommandEntryWire(name: "hookify:list"),
        ])
    }

    func testAnEntryWithOnlyANameHasNoDescriptionHintOrAliases() throws {
        let decoded = try entry(#"{"name":"skill-x"}"#)

        XCTAssertEqual(decoded, SlashCommandEntryWire(name: "skill-x"))
        XCTAssertNil(decoded.description)
        XCTAssertNil(decoded.argumentHint)
        XCTAssertEqual(decoded.aliases, [])
        XCTAssertFalse(decoded.builtin)
    }

    func testABadEntryIsSkippedAndTheOthersSurvive() throws {
        let wire = try XCTUnwrap(sessionCommands(#"""
        {"type":"session_commands","request_id":"r","tag":"t","source":"cli","commands":[
          {"name":"one"}, {"description":"no name"}, 7, "str", {"name":5}, {"name":"two"}
        ]}
        """#))

        XCTAssertEqual(wire.commands.map(\.name), ["one", "two"])
    }

    func testUnknownFieldsOnTheFrameAndTheEntryAreIgnored() throws {
        let wire = try XCTUnwrap(sessionCommands(#"""
        {"type":"session_commands","request_id":"r","tag":"t","source":"init","future":{"a":1},
         "commands":[{"name":"x","plugin":"p","nested":[1,2]}]}
        """#))

        XCTAssertEqual(wire.source, "init")
        XCTAssertEqual(wire.commands, [SlashCommandEntryWire(name: "x")])
    }

    func testMistypedOptionalEntryFieldsDoNotCostTheEntry() throws {
        let decoded = try entry(#"{"name":"x","description":5,"argument_hint":["a"],"aliases":"y","builtin":"yes"}"#)

        XCTAssertEqual(decoded, SlashCommandEntryWire(name: "x"))
    }

    func testAMissingSourceMeansNoneAndMissingCommandsMeansEmpty() throws {
        let wire = try XCTUnwrap(sessionCommands(#"{"type":"session_commands","request_id":"r","tag":"t"}"#))

        XCTAssertEqual(wire.source, "none")
        XCTAssertEqual(wire.commands, [])
    }

    func testAFrameWithoutARequestIdOrTagIsUnknown() {
        for json in [#"{"type":"session_commands","tag":"t","source":"cli","commands":[]}"#,
                     #"{"type":"session_commands","request_id":"r","source":"cli","commands":[]}"#] {
            guard case .unknown = decodeFrame(json) else { return XCTFail(json) }
        }
    }

    func testAnUnknownMessageTypeStillDecodesToUnknown() {
        guard case .unknown = decodeFrame(#"{"type":"session_commands_v2","request_id":"r","tag":"t"}"#) else {
            return XCTFail("a future frame type must stay .unknown")
        }
        guard case .unknown = decodeFrame(#"{"no_type":true}"#) else { return XCTFail("untyped frame") }
    }

    // MARK: - Catalog: source cli

    func testACliCatalogIsTheDaemonsEntriesInOrder() {
        let commands = [SlashCommandEntryWire(name: "zeta", description: "Z"),
                        SlashCommandEntryWire(name: "alpha", description: "A", argumentHint: "<x>", aliases: ["a"])]

        let catalog = SlashCommandCatalog.make(source: "cli", commands: commands)

        XCTAssertEqual(catalog.entries, commands)
        XCTAssertFalse(catalog.isFallback)
    }

    func testACliEntryWithoutADescriptionIsFilledFromTheTableByExactName() {
        let catalog = SlashCommandCatalog.make(source: "cli", commands: [
            SlashCommandEntryWire(name: "context", argumentHint: "[h]", aliases: ["ctx"], builtin: true),
            SlashCommandEntryWire(name: "my-skill"),
            SlashCommandEntryWire(name: "Context"),
            SlashCommandEntryWire(name: "plugin:context"),
        ])

        XCTAssertEqual(catalog.entries[0].description, BuiltinSlashCommands.description(for: "context"))
        XCTAssertNotNil(catalog.entries[0].description)
        XCTAssertEqual(catalog.entries[0].argumentHint, "[h]", "filling a description keeps the other fields")
        XCTAssertEqual(catalog.entries[0].aliases, ["ctx"])
        XCTAssertTrue(catalog.entries[0].builtin)
        XCTAssertNil(catalog.entries[1].description, "a command the table does not know gets no made-up description")
        XCTAssertNil(catalog.entries[2].description, "the table is matched by exact name, not case-insensitively")
        XCTAssertNil(catalog.entries[3].description, "a namespaced command is not the built-in of the same suffix")
    }

    func testADescriptionTheDaemonGaveWinsOverTheTable() {
        let catalog = SlashCommandCatalog.make(source: "cli", commands: [
            SlashCommandEntryWire(name: "context", description: "Custom words")])

        XCTAssertEqual(catalog.entries.first?.description, "Custom words")
    }

    // MARK: - Catalog: source init

    func testAnInitCatalogHasNamesAndDescriptionsOnlyFromTheTable() {
        let catalog = SlashCommandCatalog.make(source: "init", commands: [
            SlashCommandEntryWire(name: "model"), SlashCommandEntryWire(name: "deploy-thing")])

        XCTAssertFalse(catalog.isFallback)
        XCTAssertEqual(catalog.entries.map(\.name), ["model", "deploy-thing"])
        XCTAssertEqual(catalog.entries[0].description, BuiltinSlashCommands.description(for: "model"))
        XCTAssertNil(catalog.entries[1].description)
    }

    // MARK: - Catalog: none and old daemons

    func testSourceNoneIsTheFallbackTableFlaggedAsSuch() {
        let catalog = SlashCommandCatalog.make(source: "none", commands: [])

        XCTAssertTrue(catalog.isFallback)
        XCTAssertEqual(catalog.entries, BuiltinSlashCommands.fallback)
    }

    func testAnUnknownSourceIsTheFallbackToo() {
        XCTAssertTrue(SlashCommandCatalog.make(source: "future", commands: [SlashCommandEntryWire(name: "x")]).isFallback)
    }

    func testTheStaticFallbackIsFlaggedAndIsTheTable() {
        XCTAssertTrue(SlashCommandCatalog.fallback.isFallback)
        XCTAssertEqual(SlashCommandCatalog.fallback.entries, BuiltinSlashCommands.fallback)
    }

    func testACatalogBuiltFromAWireFrameFollowsItsSource() throws {
        let cli = try XCTUnwrap(sessionCommands(#"""
        {"type":"session_commands","request_id":"r","tag":"t","source":"cli","commands":[{"name":"only-one","description":"d"}]}
        """#))
        let none = try XCTUnwrap(sessionCommands(#"{"type":"session_commands","request_id":"r","tag":"t","source":"none","commands":[]}"#))

        XCTAssertEqual(SlashCommandCatalog.make(from: cli).entries.map(\.name), ["only-one"])
        XCTAssertTrue(SlashCommandCatalog.make(from: none).isFallback)
    }
}
