import WebKit

/// The browser pane's `Work` profile (`.claude/prds/embedded-browser-pane.md`, decided 2026-10-24).
///
/// One persistent WebKit data store, shared by every web view Nostromo builds for work sites, so a
/// GitHub or Atlassian sign-in made in the review side pane is the one the browser pane (BP1a) will
/// use. **BP1a must reuse `workIdentifier`.** Nothing is imported from Safari or Chrome and Nostromo
/// never reads this store's cookies (SR4).
enum BrowserProfile {

    /// Stable identifier of the `Work` store. Changing it signs everyone out.
    static let workIdentifier = UUID(uuidString: "B4ABA640-B3C9-4174-B335-43BB568F542E")!

    /// The persistent `Work` data store. Tests must never call this: they pass a throwaway
    /// `WKWebsiteDataStore(forIdentifier: UUID())` to the factory and remove it afterwards.
    static func work() -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: workIdentifier)
    }
}
