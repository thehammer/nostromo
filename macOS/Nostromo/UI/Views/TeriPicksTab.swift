import Foundation

/// The Picks tab. Picks are Teri's own selection rather than a work source, so
/// there is no list yet: the surface shows "Coming soon" until picks exist.
enum TeriPicksTab {
    static let config = TeriTabConfig(
        tab: .picks,
        sourceName: "Picks",
        list: nil,
        emptyMessage: "Teri has not picked anything yet.")
}
