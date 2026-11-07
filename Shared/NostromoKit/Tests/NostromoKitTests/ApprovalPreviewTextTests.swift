// NostromoKit — ApprovalPreviewTextTests.swift
//
// AP7: the lines under the command on the card, which spans take the warning colour, how many lines
// a card reserves, and that an unknown state or flag never fails the request.

import XCTest
@testable import NostromoKit

final class ApprovalPreviewTextTests: XCTestCase {

    private func dir(_ path: String, dirs: UInt64 = 3, files: UInt64 = 41_208, bytes: UInt64 = 1_200_000_000,
                     atLeast: Bool = false, flags: [ApprovalPreviewFlag] = [], relative: Bool = false) -> ApprovalPreviewTarget {
        ApprovalPreviewTarget(command: "rm", path: path, relative: relative, exists: true, kind: "dir", dirs: dirs,
                              files: files, bytes: bytes, atLeast: atLeast, flags: flags)
    }

    private func preview(_ targets: [ApprovalPreviewTarget], state: ApprovalPreview.State = .complete,
                         more: Int = 0) -> ApprovalPreview {
        ApprovalPreview(state: state, targets: targets, more: more)
    }

    private func texts(_ p: ApprovalPreview, cwd: String? = "/w", home: String? = "/Users/me") -> [String] {
        ApprovalPreviewText.lines(for: p, cwd: cwd, home: home).map(\.text)
    }

    func testADirectoryLineSaysHowMuchItHolds() {
        XCTAssertEqual(texts(preview([dir("/Users/me/Library/Caches/foo")])),
                       ["~/Library/Caches/foo — 3 directories · 41,208 files · 1.2 GB"])
    }

    func testSingularCountsAreSingular() {
        XCTAssertEqual(texts(preview([dir("/tmp/x", dirs: 1, files: 1, bytes: 1)])),
                       ["/tmp/x — 1 directory · 1 file · 1 byte"])
    }

    func testAPartialCountSaysAtLeast() {
        XCTAssertEqual(texts(preview([dir("/tmp/x", atLeast: true)], state: .partial)),
                       ["/tmp/x — at least 3 directories · 41,208 files · 1.2 GB"])
    }

    func testAMissingPathDoesNotExist() {
        let t = ApprovalPreviewTarget(command: "rm", path: "/tmp/nope", exists: false)
        XCTAssertEqual(texts(preview([t])), ["/tmp/nope — does not exist"])
    }

    func testWhatCannotBeResolvedSaysSoInTheWarningColour() {
        let t = ApprovalPreviewTarget(command: "rm", cantResolve: "$DIR/x", why: "uses a variable or substitution")
        let line = ApprovalPreviewText.lines(for: preview([t]), cwd: nil)[0]
        XCTAssertEqual(line.text, "can't resolve: $DIR/x (uses a variable or substitution)")
        XCTAssertTrue(line.hasWarning)
    }

    func testFlagsAreTheWarningSpansAndNothingElseIs() {
        let line = ApprovalPreviewText.lines(for: preview([dir("/etc/x", flags: [.outsideCwd, .homeCritical])]),
                                             cwd: "/w")[0]
        XCTAssertEqual(line.spans.filter { $0.style == .warning }.map(\.text),
                       [" · outside the working folder, critical folder"])
        XCTAssertEqual(line.spans.first?.style, .normal)
    }

    func testAHomeCriticalTargetIsNotCountedButFlagged() {
        let t = ApprovalPreviewTarget(command: "rm", path: "/Users/me", exists: true, kind: "dir",
                                      flags: [.homeCritical, .notCounted])
        let line = ApprovalPreviewText.lines(for: preview([t]), cwd: "/w", home: "/Users/me")[0]
        XCTAssertEqual(line.text, "~ — not counted · critical folder")
        XCTAssertTrue(line.hasWarning)
    }

    func testNetworkAndBusyReasons() {
        let net = ApprovalPreviewTarget(command: "rm", path: "/Volumes/nas/x", flags: [.network, .notCounted])
        XCTAssertEqual(texts(preview([net])), ["/Volumes/nas/x — not counted: network or external volume"])
        let busy = ApprovalPreviewTarget(command: "rm", path: "/tmp/x", flags: [.notCounted, .busy])
        XCTAssertEqual(texts(preview([busy])), ["/tmp/x — not counted (busy)"])
    }

    func testAMoveShowsItsDestination() {
        let t = ApprovalPreviewTarget(command: "mv", path: "/tmp/a", exists: true, kind: "file", files: 1, bytes: 12, dest: "/tmp/b/")
        XCTAssertEqual(texts(preview([t])), ["/tmp/a — file · 12 bytes → /tmp/b/"])
    }

    func testASymlinkIsSaidToBeNotFollowed() {
        let t = ApprovalPreviewTarget(command: "rm", path: "/tmp/l", exists: true, kind: "symlink", flags: [.symlink])
        XCTAssertEqual(texts(preview([t])), ["/tmp/l — symlink · symlink, not followed"])
    }

    func testCountingShowsTheTargetsWithoutNumbers() {
        let t = ApprovalPreviewTarget(command: "rm", path: "/tmp/x", relative: false)
        XCTAssertEqual(texts(preview([t], state: .counting)), ["/tmp/x — counting…"])
    }

    func testARelativeTargetAddsTheStartFolderNoteInMutedText() {
        let lines = ApprovalPreviewText.lines(for: preview([dir("/w/build", relative: true)]), cwd: "/Users/me/w", home: "/Users/me")
        XCTAssertEqual(lines.last?.text, "(relative to ~/w, where the session started)")
        XCTAssertEqual(lines.last?.spans.first?.style, .muted)
    }

    func testOverTheLimitSaysAndNMore() {
        let many = (0..<8).map { dir("/tmp/d\($0)") }
        let lines = texts(preview(many, more: 3))
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(lines.last, "and 5 more")
        XCTAssertEqual(texts(preview(many.prefix(2).map { $0 }, more: 4)).last, "and 4 more")
    }

    func testReservedLinesMatchTheLinesWhateverTheCountsSay() {
        let cases: [ApprovalPreview] = [
            preview([dir("/a")]),
            preview([dir("/a", relative: true)]),
            preview((0..<9).map { dir("/d\($0)", relative: $0 == 2) }, more: 2),
            preview([dir("/a")], more: 1),
        ]
        for p in cases {
            XCTAssertEqual(ApprovalPreviewText.reservedLineCount(for: p),
                           ApprovalPreviewText.lines(for: p, cwd: "/w").count)
            // The same targets, still counting: the same number of lines.
            let counting = ApprovalPreview(state: .counting, targets: p.targets.map {
                ApprovalPreviewTarget(command: $0.command, path: $0.path, relative: $0.relative)
            }, more: p.more)
            XCTAssertEqual(ApprovalPreviewText.reservedLineCount(for: counting),
                           ApprovalPreviewText.reservedLineCount(for: p))
            XCTAssertEqual(ApprovalPreviewText.lines(for: counting, cwd: "/w").count,
                           ApprovalPreviewText.lines(for: p, cwd: "/w").count)
        }
        XCTAssertEqual(ApprovalPreviewText.reservedLineCount(for: nil), 0)
        XCTAssertEqual(ApprovalPreviewText.reservedLineCount(for: ApprovalPreview(state: .omitted, targets: [])), 0)
    }

    func testByteSizesUseDecimalUnits() {
        XCTAssertEqual(ApprovalPreviewText.size(0), "0 bytes")
        XCTAssertEqual(ApprovalPreviewText.size(999), "999 bytes")
        XCTAssertEqual(ApprovalPreviewText.size(41_200), "41.2 KB")
        XCTAssertEqual(ApprovalPreviewText.size(1_200_000_000), "1.2 GB")
    }

    // MARK: - Decoding

    func testThePreviewDecodesFromTheWire() throws {
        let request = try ApprovalFixtures.bashRequest("rm -rf build/", cwd: "/w", preview: [
            "state": "partial", "more": 2,
            "targets": [["command": "rm", "path": "/w/build", "relative": true, "exists": true, "kind": "dir",
                         "dirs": 3, "files": 41_208, "bytes": 1_200_000_000, "at_least": true,
                         "flags": ["outside_cwd"]]],
        ])
        let p = try XCTUnwrap(request.preview)
        XCTAssertEqual(p.state, .partial)
        XCTAssertEqual(p.more, 2)
        XCTAssertEqual(p.targets[0].files, 41_208)
        XCTAssertEqual(p.targets[0].flags, [.outsideCwd])
        XCTAssertTrue(p.targets[0].atLeast)
    }

    func testAnUnknownFlagIsDroppedAndAnUnknownStateIsIgnoredWithoutFailingTheRequest() throws {
        let flagged = try ApprovalFixtures.bashRequest("rm x", preview: [
            "state": "complete",
            "targets": [["command": "rm", "path": "/x", "flags": ["from_the_future", "network"]]],
        ])
        XCTAssertEqual(flagged.preview?.targets[0].flags, [.network])
        let future = try ApprovalFixtures.bashRequest("rm x", preview: ["state": "from_the_future", "targets": []])
        XCTAssertNil(future.preview)
        XCTAssertEqual(future.options.count, 4, "the request itself still decodes")
    }

    func testARequestWithoutAPreviewHasNone() throws {
        XCTAssertNil(try ApprovalFixtures.bashRequest("ls").preview)
    }

    func testThePreviewFrameDecodes() throws {
        let json = #"{"tag":"t","request_id":"r","preview":{"state":"complete","targets":[],"more":0}}"#
        let frame = try JSONDecoder().decode(ApprovalPreviewFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.requestId, "r")
        XCTAssertEqual(frame.preview.state, .complete)
    }
}
