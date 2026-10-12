import AppKit

/// The whole UI is drawn dark (hard-coded `Theme` colours on near-black), but the app
/// used to follow the system appearance. In Light mode every system-drawn label
/// (`labelColor`, popup and bezelled-button titles, the filter and sort controls)
/// resolved to dark-on-dark and the Teri tabs and toolbars were unreadable, while only
/// the explicitly coloured selected tab stayed visible. Pin the app to Dark Aqua.
///
/// The pin is load-bearing, not cosmetic: any system-adaptive colour (`labelColor`,
/// `controlBackgroundColor`, `separatorColor`, a bezelled control's own drawing) used on
/// a hard-coded dark `Theme` surface is only right because it resolves as Dark Aqua.
/// Take the pin away and those views go dark-on-dark again.
enum AppAppearance {
    static let name = NSAppearance.Name.darkAqua

    static func apply(to app: NSApplication) {
        app.appearance = NSAppearance(named: name)
    }
}
