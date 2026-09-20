// Nostromo iOS — DiffSurfaceView.swift
//
// Renders a `pr_diff` pane (ios-curated-view-parity W8): a file list and a
// selected file's hunks — the SAME two parts at both widths (D2), arranged
// two ways: compact pushes from the list to the content (`NavigationStack`);
// regular shows both side by side, list on the leading edge, in a fixed
// proportion this view chooses.
//
// This is the ONE renderer permitted to read `WidthClass`
// (`nostromoWidthClass`) — memo B9/W6's D8 name this file as the sole
// intended consumer beyond `DynamicFocusView`/`RegionContainerView`
// themselves; `tests/ios_policy/test_ios_view_policy.py`'s
// `WIDTH_CLASS_ALLOWLIST` enforces that structurally. `DiffFileListView` and
// `DiffFileContentView` take identical parameters at both widths and never
// reference it.
//
// D3 — THE ANCHORED BYPASS. An address carrying a resolvable
// `Anchor.line(path:line:)` opens that file's content directly — the list
// is never shown first and never has to be tapped through. `selectedFile`
// (below) is a pure read of persisted state (`FocusRegionState`, via
// `restoreSelectedFile`); `applyFreshAnchor(_:)` is the ONLY place that ever
// WRITES to it, and it writes only on a freshly-`.resolved` anchor. A push
// whose anchor is `.unresolved` (a bad path, an anchor kind this surface
// can't use) or absent (`.notRequested`) never touches the persisted
// selection — it only ever ADDS a selection, never subtracts one. This is
// what makes "falls back to the list" true on a genuinely fresh pane (no
// selection yet, so `selectedFile == nil`) without also force-closing a
// file the operator is already reading because an unrelated later push
// happened to carry a bad anchor.
//
// D4 — `tooLarge` replaces the ENTIRE surface with a stated notice, checked
// first, before either width's body — never an empty file list, which would
// be indistinguishable from a PR that changes nothing.
//
// Selected-file persistence and per-file scroll restore both go through
// `FocusRegionState` (via closures bound in `DynamicFocusView`/
// `PaneSurfaceView`, exactly like `CodeSurfaceView`'s `saveScrollKey`/
// `restoreScroll`), never view `@State` — see this file's `navPath`
// property for the one exception, which is explicitly seeded FROM that
// persisted state at `init` time so a width-class rebuild reconstructs the
// same navigation stack rather than losing it.
import SwiftUI
import NostromoKit

struct DiffSurfaceView: View {
    let payload: DiffPayload
    let address: PaneAddress?
    /// Per-file scroll-restore (paired with `restoreScroll` below) — `file`
    /// is supplied by this view at the call site, since `PaneSurfaceView`
    /// (which binds these closures to a `tag`/`paneId`) has no notion of
    /// "which file" at all; that's entirely internal to this surface.
    let saveScrollKey: (_ file: String, _ key: Int) -> Void
    let restoreScroll: (_ file: String, _ visibleRange: ClosedRange<Int>?) -> ScrollRestore
    /// The selected-file slot (D2), scoped by an identity string
    /// (`"\(repo)#\(number)"`-shaped, built by `identity` below) this view
    /// supplies at the call site for the same reason.
    let saveSelectedFile: (_ path: String, _ identity: String) -> Void
    let restoreSelectedFile: (_ identity: String) -> String?

    @Environment(\.nostromoWidthClass) private var widthClass

    /// Rebuilt only when `payload` changes — the same identity rule
    /// `CodeSurfaceView.document` uses, and for the same reason: an
    /// address-only push must never force a full reflatten.
    @State private var document: DiffDocument

    /// The compact presentation's own navigation stack. Seeded in `init`
    /// FROM the persisted selected-file slot (never the other way around),
    /// so a width-class rebuild reconstructs the same stack instead of
    /// losing it, and so a resolvable anchor is already pushed before the
    /// first frame renders — the operator must never see the list flash
    /// before the content (D3).
    @State private var navPath: [String]

    init(
        payload: DiffPayload,
        address: PaneAddress?,
        saveScrollKey: @escaping (_ file: String, _ key: Int) -> Void,
        restoreScroll: @escaping (_ file: String, _ visibleRange: ClosedRange<Int>?) -> ScrollRestore,
        saveSelectedFile: @escaping (_ path: String, _ identity: String) -> Void,
        restoreSelectedFile: @escaping (_ identity: String) -> String?
    ) {
        self.payload = payload
        self.address = address
        self.saveScrollKey = saveScrollKey
        self.restoreScroll = restoreScroll
        self.saveSelectedFile = saveSelectedFile
        self.restoreSelectedFile = restoreSelectedFile

        let doc = DiffDocument(payload: payload)
        _document = State(initialValue: doc)

        let identity = DiffSurfaceView.identity(for: payload)
        let initialFile = DiffSurfaceView.initiallySelectedFile(
            document: doc, address: address, identity: identity, restoreSelectedFile: restoreSelectedFile
        )
        _navPath = State(initialValue: initialFile.map { [$0] } ?? [])
    }

    // MARK: - Resolved row/path — the one guard `applyFreshAnchor`,
    // `scrollTarget(for:)`, `initiallySelectedFile`, and `body`'s
    // `onChange(of: address)` all otherwise repeat: a `.resolved` anchor
    // names a row only within `document.rows`'s current bounds.

    /// The row `resolution` names, or `nil` when it isn't `.resolved` at all
    /// or names a row past `document`'s current bounds.
    private static func resolvedRow(in document: DiffDocument, resolution: AnchorResolution) -> Int? {
        guard case .resolved(let row) = resolution, document.rows.indices.contains(row) else { return nil }
        return row
    }

    /// The file `resolution` names, via `resolvedRow(in:resolution:)`.
    private static func resolvedPath(in document: DiffDocument, resolution: AnchorResolution) -> String? {
        resolvedRow(in: document, resolution: resolution).flatMap { document.rows[$0].path }
    }

    private func resolvedRow(from resolution: AnchorResolution) -> Int? {
        DiffSurfaceView.resolvedRow(in: document, resolution: resolution)
    }

    private func resolvedPath(from resolution: AnchorResolution) -> String? {
        DiffSurfaceView.resolvedPath(in: document, resolution: resolution)
    }

    // MARK: - Resolution (D3) — pure functions of `document` and `address`.

    private var identity: String { DiffSurfaceView.identity(for: payload) }

    private var anchorResolution: AnchorResolution {
        document.resolve(anchor: address?.anchor)
    }

    private var emphasisResolution: EmphasisResolution {
        document.resolve(emphasis: address?.emphasis ?? [])
    }

    /// The persisted file this pane currently has open, or `nil` to show
    /// the list. A PURE read — `applyFreshAnchor(_:)` is the only writer.
    private var selectedFile: String? {
        restoreSelectedFile(identity)
    }

    /// The reason a requested anchor could not be resolved, shown above the
    /// list — never above an already-open file (see this file's header
    /// comment on why an unresolved LATER push doesn't force-close it).
    private var anchorNotice: String? {
        switch anchorResolution {
        case .notRequested, .resolved:
            return nil
        case .unresolved(let reason):
            return reason
        }
    }

    private var emphasisRows: Set<Int> {
        switch emphasisResolution {
        case .none, .matchedNothing:
            return []
        case .rows(let rows):
            return Set(rows)
        }
    }

    /// The reason an emphasis range matched nothing in this diff, shown
    /// above the open file's content.
    private var emphasisNotice: String? {
        switch emphasisResolution {
        case .none, .rows:
            return nil
        case .matchedNothing(let reason):
            return reason
        }
    }

    var body: some View {
        Group {
            if document.tooLarge {
                tooLargeNotice
            } else {
                switch widthClass {
                case .compact: compactBody
                case .regular: regularBody
                }
            }
        }
        .onChange(of: payload) { _, newPayload in
            document = DiffDocument(payload: newPayload)
        }
        .onAppear {
            applyFreshAnchor(anchorResolution)
        }
        .onChange(of: address) { _, _ in
            let resolution = anchorResolution
            applyFreshAnchor(resolution)
            if widthClass == .compact, let path = resolvedPath(from: resolution) {
                navPath = [path]
            }
        }
    }

    /// Persist a freshly-`.resolved` anchor's file as this pane's open file
    /// (D2/D3). `.unresolved`/`.notRequested` leave whatever was previously
    /// persisted untouched — see this file's header comment.
    private func applyFreshAnchor(_ resolution: AnchorResolution) {
        guard let path = resolvedPath(from: resolution) else { return }
        saveSelectedFile(path, identity)
    }

    private static func identity(for payload: DiffPayload) -> String {
        "\(payload.repo)#\(payload.number.map(String.init) ?? "none")"
    }

    private static func initiallySelectedFile(
        document: DiffDocument, address: PaneAddress?, identity: String,
        restoreSelectedFile: (String) -> String?
    ) -> String? {
        let resolution = document.resolve(anchor: address?.anchor)
        if let path = resolvedPath(in: document, resolution: resolution) {
            return path
        }
        return restoreSelectedFile(identity)
    }

    // MARK: - tooLarge (D4) — the whole surface, never one row among many.

    private var tooLargeNotice: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 60)
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(document.rows.first?.text ?? "diff too large to render")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compact (D2, D3) — list, push to content, content stays reachable.

    private var compactBody: some View {
        NavigationStack(path: $navPath) {
            listBody
                .navigationDestination(for: String.self) { path in
                    contentView(for: path)
                }
        }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            if let anchorNotice, selectedFile == nil {
                NoticeBanner(text: anchorNotice)
            }
            DiffFileListView(files: payload.files, onSelect: { path in
                saveSelectedFile(path, identity)
                navPath = [path]
            })
        }
    }

    // MARK: - Regular (D2) — side by side, selecting a file never loses the list.

    private var regularBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let anchorNotice, selectedFile == nil {
                    NoticeBanner(text: anchorNotice)
                }
                DiffFileListView(files: payload.files, onSelect: { path in
                    saveSelectedFile(path, identity)
                })
            }
            .frame(width: 260)
            Divider()
            if let selectedFile {
                contentView(for: selectedFile)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack {
            Spacer(minLength: 60)
            Text("Select a file")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    private func contentView(for path: String) -> some View {
        Group {
            if let file = payload.files.first(where: { $0.path == path }) {
                DiffFileContentView(
                    document: document,
                    file: file,
                    scrollTarget: scrollTarget(for: path),
                    emphasisRows: emphasisRows,
                    emphasisNotice: emphasisNotice,
                    saveScrollKey: { key in saveScrollKey(path, key) },
                    restoreScroll: { range in restoreScroll(path, range) }
                )
            }
        }
        .id(path)
    }

    /// The resolved row to scroll to, but only when it actually belongs to
    /// `path` — a persisted selection from a stale anchor for a DIFFERENT
    /// file must never hand this file a scroll target that isn't its own.
    private func scrollTarget(for path: String) -> Int? {
        guard let row = resolvedRow(from: anchorResolution), document.rows[row].path == path else { return nil }
        return row
    }
}
