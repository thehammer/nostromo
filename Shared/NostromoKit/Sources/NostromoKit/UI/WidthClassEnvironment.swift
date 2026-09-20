// NostromoKit — WidthClassEnvironment.swift
//
// Publishes the app's `WidthClass` down the SwiftUI view tree (W6 —
// ios-curated-view-parity, D8).
//
// `DynamicFocusView` is the one place that READS
// `@Environment(\.horizontalSizeClass)` and the one place that maps it to a
// `WidthClass`. It publishes the result here so a surface renderer can
// consume it as a plain value without re-reading the size class — because
// there is exactly one renderer that will legitimately need to know:
// `pr_diff` (W8), whose Decision-4 behaviour is to put the file list beside
// the file's hunks when there's room. That's the same two parts rearranged —
// a property of the diff renderer, not of the region layout — so the value
// has to be reachable from a surface.
//
// It is recorded here, in the type's own doc comment rather than only in a
// plan, so this does not later read as the first "just this one thing
// different on iPad" exception the PRD warns about. The L2 policy suite
// (`tests/ios_policy/test_ios_view_policy.py`) carries an EXPLICIT allowlist
// of the files permitted to name `WidthClass` at all — the focus view, the
// region container, and from W8 the diff surface — so adding a consumer
// requires editing the policy and therefore noticing.
//
// Defaults to `.compact`: a view rendered with no ancestor publishing a
// width gets the presentation that is correct everywhere.
import SwiftUI

private struct WidthClassKey: EnvironmentKey {
    static let defaultValue: WidthClass = .compact
}

public extension EnvironmentValues {
    /// The app's current horizontal width class, published by the focus view.
    /// See this file's header for who is permitted to read it.
    var nostromoWidthClass: WidthClass {
        get { self[WidthClassKey.self] }
        set { self[WidthClassKey.self] = newValue }
    }
}
